"""Fine-tuning TimesFM 3 on the user's own series (PyTorch, Apple GPU via MPS).

The public TimesFM 3 PyTorch model is inference-only (``decode`` runs under ``no_grad``), but the
underlying computation is differentiable, so we call the undecorated function and train with a
quantile (pinball) loss on held-out horizons. LoRA adapters are merged back into the weights at the
end, so every fine-tuned model is a plain ``config.json`` + ``model.safetensors`` checkpoint that
both the MLX and the PyTorch backends load exactly like the base model.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import math
import os
import re
import shutil
import time
from typing import Any

import numpy as np

from . import data as data_lib
from .jobs import Job
from .runtime import QUANTILE_LEVELS, EngineError, _model_path

ATTENTION_MODULES = ("query_proj", "key_proj", "value_proj", "out_proj")
FEEDFORWARD_MODULES = ("ff0", "ff1")


@dataclasses.dataclass
class FinetuneConfig:
  base_model_id: str
  output_name: str = ""
  context_length: int = 512
  horizon: int = 64
  mode: str = "joint"  # joint: targets are variates of one window; independent: one window per target
  method: str = "lora"  # lora | last_layers | head | full
  lora_rank: int = 8
  lora_alpha: float = 16.0
  lora_dropout: float = 0.05
  lora_targets: list[str] = dataclasses.field(default_factory=lambda: ["attention", "feedforward"])
  train_last_layers: int = 4
  epochs: int = 5
  windows_per_epoch: int = 1024
  batch_size: int = 16
  learning_rate: float = 1e-4
  weight_decay: float = 0.0
  warmup_ratio: float = 0.05
  grad_clip: float = 1.0
  loss: str = "quantile"  # quantile | mse
  val_fraction: float = 0.2
  max_val_windows: int = 64
  early_stopping_patience: int = 3  # epochs without improvement; 0 disables
  device: str = "mps"  # mps | cpu
  seed: int = 42


# --------------------------------------------------------------------------- windows


@dataclasses.dataclass
class _Windows:
  target: np.ndarray  # (N, u, ctx)
  future: np.ndarray  # (N, u, h)
  po: np.ndarray | None  # (N, v, ctx)
  pf: np.ndarray | None  # (N, w, ctx + h)


def _units(groups: list[data_lib.SeriesGroup], mode: str) -> list[tuple[np.ndarray, np.ndarray | None, np.ndarray | None]]:
  """Training units: (targets (u, T), past cov (v, T) | None, future cov (w, T') | None)."""
  units = []
  for g in groups:
    T = g.targets.shape[1]
    pf = g.future_cov[:, :T] if g.future_cov is not None else None
    if mode == "independent":
      for r in range(g.targets.shape[0]):
        units.append((g.targets[r : r + 1], g.past_cov, pf))
    else:
      units.append((g.targets, g.past_cov, pf))
  return units


def _cut(unit, end: int, ctx: int, h: int) -> tuple:
  tgt, po, pf = unit
  return (
    tgt[:, end - ctx : end],
    tgt[:, end : end + h],
    po[:, end - ctx : end] if po is not None else None,
    pf[:, end - ctx : end + h] if pf is not None else None,
  )


def _stack(parts: list[tuple]) -> _Windows:
  return _Windows(
    target=np.stack([p[0] for p in parts]).astype(np.float32),
    future=np.stack([p[1] for p in parts]).astype(np.float32),
    po=np.stack([p[2] for p in parts]).astype(np.float32) if parts[0][2] is not None else None,
    pf=np.stack([p[3] for p in parts]).astype(np.float32) if parts[0][3] is not None else None,
  )


def build_windows(groups, cfg: FinetuneConfig, rng: np.random.Generator, job: Job | None = None):
  units = _units(groups, cfg.mode)
  h = int(cfg.horizon)
  lengths = [u[0].shape[1] for u in units]
  splits = [max(h + 2, int(round(T * (1 - cfg.val_fraction)))) for T in lengths]
  # Largest context every unit can provide for at least one training window.
  max_ctx = min(s - h for s in splits)
  ctx = min(int(cfg.context_length), max_ctx)
  if ctx < 16:
    raise EngineError(
      f"Series are too short to fine-tune with horizon {h}: the shortest training split leaves only "
      f"{max_ctx} points of context. Lower the horizon or the validation fraction, or use longer series."
    )
  if ctx < cfg.context_length and job:
    job.log(f"Context length reduced from {cfg.context_length} to {ctx} to fit the shortest series.")

  # Validation: non-overlapping windows whose horizon lies in the held-out tail.
  val_parts = []
  for u, T, s in zip(units, lengths, splits):
    end = T - h
    while end >= max(s, ctx) and len(val_parts) < cfg.max_val_windows * len(units):
      val_parts.append(_cut(u, end, ctx, h))
      end -= h
  if not val_parts:  # tail too short: validate on the last window of each unit
    for u, T in zip(units, lengths):
      if T - h >= ctx:
        val_parts.append(_cut(u, T - h, ctx, h))
  if len(val_parts) > cfg.max_val_windows:
    idx = rng.choice(len(val_parts), cfg.max_val_windows, replace=False)
    val_parts = [val_parts[i] for i in sorted(idx)]

  # Training: every window whose horizon ends before the split point.
  train_index = [(ui, end) for ui, (T, s) in enumerate(zip(lengths, splits)) for end in range(ctx, s - h + 1)]
  if not train_index:
    raise EngineError("No training windows fit before the validation split. Lower the validation fraction.")
  return units, ctx, train_index, (_stack(val_parts) if val_parts else None)


# --------------------------------------------------------------------------- LoRA


def _make_lora_linear():
  import torch
  from torch import nn

  class LoRALinear(nn.Module):
    def __init__(self, base: nn.Linear, rank: int, alpha: float, dropout: float):
      super().__init__()
      self.base = base
      for p in self.base.parameters():
        p.requires_grad_(False)
      self.lora_a = nn.Parameter(torch.empty(rank, base.in_features, device=base.weight.device))
      self.lora_b = nn.Parameter(torch.zeros(base.out_features, rank, device=base.weight.device))
      nn.init.kaiming_uniform_(self.lora_a, a=math.sqrt(5))
      self.scale = alpha / rank
      self.dropout = nn.Dropout(dropout) if dropout > 0 else nn.Identity()
      self.active_dropout = False

    def forward(self, x):
      z = self.dropout(x) if self.active_dropout else x
      return self.base(x) + (z @ self.lora_a.t() @ self.lora_b.t()) * self.scale

    @torch.no_grad()
    def merged(self) -> nn.Linear:
      self.base.weight += (self.lora_b @ self.lora_a) * self.scale
      return self.base

  return LoRALinear


def _replace_module(root, name: str, new) -> None:
  parent = root
  *path, last = name.split(".")
  for p in path:
    parent = getattr(parent, p)
  setattr(parent, last, new)


def _lora_target_names(cfg: FinetuneConfig) -> tuple[str, ...]:
  names: list[str] = []
  if "attention" in cfg.lora_targets:
    names += ATTENTION_MODULES
  if "feedforward" in cfg.lora_targets:
    names += FEEDFORWARD_MODULES
  if "head" in cfg.lora_targets:
    names.append("output_head")
  if "input" in cfg.lora_targets:
    names += ("hidden_layer", "output_layer", "residual_layer")
  return tuple(names)


def setup_trainable(model, cfg: FinetuneConfig, log) -> list:
  from torch import nn

  for p in model.parameters():
    p.requires_grad_(False)
  if cfg.method == "full":
    for p in model.parameters():
      p.requires_grad_(True)
  elif cfg.method == "head":
    for p in model.output_head.parameters():
      p.requires_grad_(True)
  elif cfg.method == "last_layers":
    layers = model.transformer_stack.layers
    n = max(1, min(int(cfg.train_last_layers), len(layers)))
    for layer in list(layers)[-n:]:
      for p in layer.parameters():
        p.requires_grad_(True)
    for p in model.output_head.parameters():
      p.requires_grad_(True)
    log(f"Training the last {n} of {len(layers)} transformer layers + output head.")
  elif cfg.method == "lora":
    LoRALinear = _make_lora_linear()
    targets = _lora_target_names(cfg)
    if not targets:
      raise EngineError("Pick at least one LoRA target (attention, feedforward, head or input).")
    wrapped = 0
    for name, mod in list(model.named_modules()):
      if isinstance(mod, nn.Linear) and name.split(".")[-1] in targets:
        _replace_module(model, name, LoRALinear(mod, int(cfg.lora_rank), float(cfg.lora_alpha), float(cfg.lora_dropout)))
        wrapped += 1
    log(f"LoRA rank {cfg.lora_rank}, alpha {cfg.lora_alpha} on {wrapped} linear layers ({', '.join(cfg.lora_targets)}).")
  else:
    raise EngineError(f"Unknown fine-tuning method '{cfg.method}'.")
  params = [p for p in model.parameters() if p.requires_grad]
  total = sum(p.numel() for p in model.parameters())
  trainable = sum(p.numel() for p in params)
  log(f"Trainable parameters: {trainable:,} of {total:,} ({100 * trainable / total:.2f}%).")
  return params


def merge_lora(model) -> int:
  merged = 0
  for name, mod in list(model.named_modules()):
    if type(mod).__name__ == "LoRALinear":
      _replace_module(model, name, mod.merged())
      merged += 1
  return merged


def _set_lora_dropout(model, active: bool) -> None:
  for mod in model.modules():
    if type(mod).__name__ == "LoRALinear":
      mod.active_dropout = active


# --------------------------------------------------------------------------- loss


def _loss(pred, future, context, kind: str):
  """pred: (b, u, h, q); future: (b, u, h); context: (b, u, ctx). Scale-free per window/variate."""
  import torch

  scale = context.std(dim=-1, keepdim=True)
  scale = torch.where(scale > 1e-6, scale, torch.ones_like(scale))
  if kind == "mse":
    return (((pred[..., 4] - future) / scale) ** 2).mean()
  levels = torch.tensor(QUANTILE_LEVELS, device=pred.device, dtype=pred.dtype)
  diff = (future.unsqueeze(-1) - pred) / scale.unsqueeze(-1)
  return torch.maximum(levels * diff, (levels - 1) * diff).mean()


# --------------------------------------------------------------------------- gradients


def _safe_sqrt(x):
  """sqrt with a gradient of 0 at 0. The values are the same as torch.sqrt."""
  import torch

  positive = x > 0
  return torch.where(positive, torch.sqrt(torch.where(positive, x, torch.ones_like(x))), torch.zeros_like(x))


@contextlib.contextmanager
def _trainable_running_stats():
  """Lets gradients pass through TimesFM's running statistics.

  They take sqrt(variance). A series that is flat for a stretch (a holiday flag, a promo column)
  has variance 0 there, where the gradient of sqrt is infinite. One such window turns every weight
  into NaN on the first step. Inference never sees it, because it runs without gradients.
  """
  import torch
  from timesfm3.torch import util

  class SafeTorch:
    sqrt = staticmethod(_safe_sqrt)

    def __getattr__(self, name):
      return getattr(torch, name)

  original = util.torch
  util.torch = SafeTorch()
  try:
    yield
  finally:
    util.torch = original


# --------------------------------------------------------------------------- training


def _slugify(name: str) -> str:
  s = re.sub(r"[^A-Za-z0-9._-]+", "-", name.strip()).strip("-.")
  return s[:80] or "timesfm3-finetuned"


def unique_model_dir(models_dir: str, name: str) -> tuple[str, str]:
  base = _slugify(name)
  cand, i = base, 2
  while os.path.exists(os.path.join(models_dir, cand)):
    cand = f"{base}-{i}"
    i += 1
  return cand, os.path.join(models_dir, cand)


def run_finetune(
  job: Job,
  models_dir: str,
  groups: list[data_lib.SeriesGroup],
  cfg: FinetuneConfig,
  dataset_info: dict[str, Any],
) -> dict[str, Any]:
  import torch
  from timesfm3.torch.model import TimesFM3Torch

  decode = TimesFM3Torch.decode.__wrapped__  # the differentiable body of decode()

  base_path = _model_path(models_dir, cfg.base_model_id)
  rng = np.random.default_rng(cfg.seed)
  torch.manual_seed(cfg.seed)

  if cfg.device == "mps" and not torch.backends.mps.is_available():
    job.log("MPS is not available; falling back to CPU.")
    cfg.device = "cpu"
  device = torch.device(cfg.device)

  job.update(0.01, "Preparing training windows")
  units, ctx, train_index, val = build_windows(groups, cfg, rng, job)
  h = int(cfg.horizon)
  job.log(
    f"{len(units)} series unit(s), context {ctx}, horizon {h}: {len(train_index):,} possible training windows, "
    f"{0 if val is None else len(val.target)} validation windows."
  )
  if len(train_index) < 4 * max(1, int(cfg.batch_size)):
    job.log(
      f"Only {len(train_index)} distinct training windows: each epoch sees the same few examples. "
      "A shorter context length, a smaller validation tail, or more series gives the model more to learn from."
    )

  job.update(0.02, "Loading base model")
  model = TimesFM3Torch.from_pretrained(base_path, local_files_only=True)
  model.to(device)
  model.eval()  # no dropout inside the base model; LoRA dropout is toggled separately
  params = setup_trainable(model, cfg, job.log)
  model.to(device)

  opt = torch.optim.AdamW(params, lr=cfg.learning_rate, weight_decay=cfg.weight_decay)
  bs = max(1, int(cfg.batch_size))
  steps_per_epoch = max(1, math.ceil(min(cfg.windows_per_epoch, max(len(train_index), bs)) / bs))
  total_steps = steps_per_epoch * max(1, int(cfg.epochs))
  warmup = int(total_steps * cfg.warmup_ratio)

  def lr_at(step: int) -> float:
    if warmup and step < warmup:
      return cfg.learning_rate * (step + 1) / warmup
    t = (step - warmup) / max(1, total_steps - warmup)
    return cfg.learning_rate * 0.5 * (1 + math.cos(math.pi * min(1.0, t)))

  def to_t(a):
    return None if a is None else torch.from_numpy(a).to(device)

  def forward(w: _Windows):
    with _trainable_running_stats():
      out = decode(model, to_t(w.target), horizon=h, past_only_covariates=to_t(w.po), past_future_covariates=to_t(w.pf))
    return out[:, : w.target.shape[1], :h]  # decode also returns rows for the covariates

  def evaluate() -> dict[str, float] | None:
    if val is None:
      return None
    _set_lora_dropout(model, False)
    losses, maes, n = [], [], 0
    with torch.no_grad():
      for i in range(0, len(val.target), bs):
        job.check_cancel()
        w = _Windows(
          val.target[i : i + bs],
          val.future[i : i + bs],
          None if val.po is None else val.po[i : i + bs],
          None if val.pf is None else val.pf[i : i + bs],
        )
        pred = forward(w)
        fut, ctx_t = to_t(w.future), to_t(w.target)
        k = len(w.target)
        losses.append(float(_loss(pred, fut, ctx_t, "quantile")) * k)
        maes.append(float((pred[..., 4] - fut).abs().mean()) * k)
        n += k
    return {"val_loss": sum(losses) / n, "val_mae": sum(maes) / n}

  def trainable_state() -> dict[str, torch.Tensor]:
    return {k: v.detach().to("cpu").clone() for k, v in model.named_parameters() if v.requires_grad}

  job.check_cancel()
  job.update(0.03, "Zero-shot validation")
  baseline = evaluate()
  if baseline and not math.isfinite(baseline["val_loss"]):
    raise EngineError("The base model cannot be scored on this data (the validation loss is not a number). Check the columns for extreme values.")
  if baseline:
    job.log(f"Zero-shot validation: pinball loss {baseline['val_loss']:.5f}, MAE {baseline['val_mae']:.5g}")
    job.add_metric(kind="val", epoch=0, step=0, **baseline)
  best = baseline["val_loss"] if baseline else float("inf")
  best_state = trainable_state() if baseline else None
  best_epoch = 0
  bad_epochs = 0

  step = 0
  t_start = time.time()
  stopped_early = False
  for epoch in range(1, int(cfg.epochs) + 1):
    sample = rng.choice(len(train_index), size=steps_per_epoch * bs, replace=len(train_index) < steps_per_epoch * bs)
    running = []
    for s in range(steps_per_epoch):
      job.check_cancel()
      if job.finish_requested:
        stopped_early = True
        break
      _set_lora_dropout(model, True)
      parts = [_cut(units[train_index[j][0]], train_index[j][1], ctx, h) for j in sample[s * bs : (s + 1) * bs]]
      w = _stack(parts)
      for g in opt.param_groups:
        g["lr"] = lr_at(step)
      pred = forward(w)
      loss = _loss(pred, to_t(w.future), to_t(w.target), cfg.loss)
      lv = float(loss.detach())
      if not math.isfinite(lv):
        raise EngineError("Training diverged (loss is NaN/inf). Lower the learning rate.")
      opt.zero_grad(set_to_none=True)
      loss.backward()
      clip = cfg.grad_clip if cfg.grad_clip and cfg.grad_clip > 0 else float("inf")
      # A step with a NaN gradient would destroy the weights; the loss only shows it one step later.
      if not math.isfinite(float(torch.nn.utils.clip_grad_norm_(params, clip))):
        raise EngineError("Training diverged (the gradient is NaN/inf). Lower the learning rate.")
      opt.step()
      step += 1
      running.append(lv)
      elapsed = time.time() - t_start
      eta = elapsed / step * (total_steps - step)
      if step % max(1, steps_per_epoch // 50) == 0 or s == steps_per_epoch - 1:
        job.add_metric(kind="train", epoch=epoch, step=step, loss=float(np.mean(running[-10:])), lr=lr_at(step))
      job.update(0.04 + 0.9 * step / total_steps, f"Epoch {epoch}/{cfg.epochs} · step {step}/{total_steps} · loss {lv:.4f} · ETA {eta:.0f}s")

    ev = evaluate()
    train_loss = float(np.mean(running)) if running else None
    train_text = "no training steps" if train_loss is None else f"train {train_loss:.5f}"
    if ev and not math.isfinite(ev["val_loss"]):
      raise EngineError("Training diverged (the validation loss is NaN/inf). Lower the learning rate.")
    if ev:
      job.add_metric(kind="val", epoch=epoch, step=step, train_loss=train_loss, **ev)
      improved = ev["val_loss"] < best - 1e-7
      job.log(
        f"Epoch {epoch}: {train_text} · val loss {ev['val_loss']:.5f} · val MAE {ev['val_mae']:.5g}"
        + (" (best)" if improved else "")
      )
      if improved:
        best, best_state, best_epoch, bad_epochs = ev["val_loss"], trainable_state(), epoch, 0
      else:
        bad_epochs += 1
        if cfg.early_stopping_patience and bad_epochs >= cfg.early_stopping_patience:
          job.log(f"Early stopping: no improvement for {bad_epochs} epoch(s).")
          break
    else:
      job.log(f"Epoch {epoch}: {train_text}")
      best_state, best_epoch = trainable_state(), epoch
    if stopped_early:
      job.log("Stopped early by user; saving the best weights so far.")
      break

  job.check_cancel()
  if best_epoch == 0 and baseline:
    job.log("Fine-tuning never beat the zero-shot model on validation; saving the zero-shot weights unchanged.")
  if best_state is not None:
    model.load_state_dict({k: v.to(device) for k, v in best_state.items()}, strict=False)

  job.update(0.96, "Saving model")
  merged = merge_lora(model)
  if merged:
    job.log(f"Merged {merged} LoRA adapters into the weights.")
  model_id, out_dir = unique_model_dir(models_dir, cfg.output_name or f"{cfg.base_model_id}-ft-{time.strftime('%Y%m%d-%H%M')}")
  tmp_dir = out_dir + ".partial"
  shutil.rmtree(tmp_dir, ignore_errors=True)
  model.to("cpu")
  model.save_pretrained(tmp_dir)
  for extra in ("LICENSE",):
    src = os.path.join(base_path, extra)
    if os.path.isfile(src):
      shutil.copy(src, os.path.join(tmp_dir, extra))
  base_meta = {}
  base_meta_path = os.path.join(base_path, "cogl_meta.json")
  if os.path.isfile(base_meta_path):
    with open(base_meta_path) as f:
      base_meta = json.load(f)
  meta = {
    "kind": "finetuned",
    "display_name": model_id,
    "base_model": cfg.base_model_id,
    "base_source": base_meta.get("repo") or base_meta.get("base_source"),
    "license": base_meta.get("license", "TimesFM Non-Commercial License v1.0 (inherited from base weights)"),
    "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "config": dataclasses.asdict(cfg),
    "effective_context_length": ctx,
    "dataset": dataset_info,
    "zero_shot_val": baseline,
    "best_val_loss": best if math.isfinite(best) else None,
    "best_epoch": best_epoch,
    "train_seconds": time.time() - t_start,
  }
  with open(os.path.join(tmp_dir, "cogl_meta.json"), "w") as f:
    json.dump(meta, f, indent=2)
  os.replace(tmp_dir, out_dir)
  job.log(f"Saved fine-tuned model as '{model_id}'.")
  if device.type == "mps":
    torch.mps.empty_cache()
  improvement = None
  if baseline and math.isfinite(best):
    improvement = 100 * (1 - best / baseline["val_loss"]) if baseline["val_loss"] > 0 else None
  return {
    "model_id": model_id,
    "path": out_dir,
    "best_epoch": best_epoch,
    "zero_shot_val_loss": baseline["val_loss"] if baseline else None,
    "best_val_loss": best if math.isfinite(best) else None,
    "improvement_percent": improvement,
  }
