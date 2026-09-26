"""Model library, loading, and forecasting with TimesFM 3."""

from __future__ import annotations

import dataclasses
import json
import math
import os
import resource
import shutil
import threading
import time
import uuid
from typing import Any

import numpy as np
import pandas as pd

from . import data as data_lib

QUANTILE_LEVELS = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
MAX_CONTEXT = 15360

# Model flags that are read at inference time, so they can be changed on an already-built model.
RUNTIME_FLAGS = (
  "use_stitching",
  "use_linear_detrending",
  "linear_detrending_threshold",
  "use_iterative_cpm_revin",
  "value_clip",
  "use_frozen_running_stats",
)


class EngineError(RuntimeError):
  """A user-facing error in model handling or forecasting."""


# --------------------------------------------------------------------------- model library


def list_models(models_dir: str) -> list[dict[str, Any]]:
  out = []
  if not os.path.isdir(models_dir):
    return out
  for name in sorted(os.listdir(models_dir)):
    path = os.path.join(models_dir, name)
    cfg_path = os.path.join(path, "config.json")
    weights = os.path.join(path, "model.safetensors")
    if not (os.path.isdir(path) and os.path.isfile(cfg_path) and os.path.isfile(weights)):
      continue
    meta = {}
    meta_path = os.path.join(path, "cogl_meta.json")
    if os.path.isfile(meta_path):
      try:
        with open(meta_path) as f:
          meta = json.load(f)
      except (OSError, json.JSONDecodeError):
        meta = {}
    try:
      with open(cfg_path) as f:
        cfg = json.load(f)
    except (OSError, json.JSONDecodeError):
      continue
    tc = cfg.get("transformer_config", {})
    out.append(
      {
        "id": name,
        "path": path,
        "size_bytes": os.path.getsize(weights),
        "kind": meta.get("kind", "base"),
        "source": meta.get("source"),
        "display_name": meta.get("display_name", name),
        "meta": meta,
        "architecture": {
          "num_layers": tc.get("num_layers"),
          "model_dims": tc.get("transformer", {}).get("model_dims"),
          "num_heads": tc.get("transformer", {}).get("num_heads"),
          "input_patch_len": cfg.get("input_patch_len"),
          "output_patch_len": cfg.get("output_patch_len"),
          "quantiles": cfg.get("quantiles"),
        },
        "flags": {k: cfg.get(k) for k in RUNTIME_FLAGS + ("use_variate_attention",)},
      }
    )
  return out


def delete_model(models_dir: str, model_id: str) -> None:
  path = _model_path(models_dir, model_id)
  shutil.rmtree(path)


def _model_path(models_dir: str, model_id: str) -> str:
  if not model_id or "/" in model_id or model_id.startswith("."):
    raise EngineError(f"Invalid model id: {model_id!r}")
  path = os.path.join(models_dir, model_id)
  if not os.path.isfile(os.path.join(path, "model.safetensors")):
    raise EngineError(f"Model '{model_id}' is not downloaded. Download it from the Models page first.")
  return path


# --------------------------------------------------------------------------- load options


@dataclasses.dataclass
class LoadOptions:
  model_id: str
  backend: str = "mlx"  # mlx | torch-mps | torch-cpu
  compile: bool = True  # MLX only
  per_core_batch_size: int = 32
  max_context_length: int = MAX_CONTEXT
  overrides: dict[str, Any] = dataclasses.field(default_factory=dict)


@dataclasses.dataclass
class ForecastOptions:
  horizon: int = 32
  context_length: int | None = None  # None = all available history (capped at max context)
  mode: str = "joint"  # joint (multivariate) | independent (each target alone)
  use_symmetric_averaging: bool = False
  use_znorm: bool = False
  make_positive: bool = False
  sort_quantiles: bool = True
  padding_mode: str = "none"  # none | edge
  backtest: bool = False
  backtest_windows: int = 1
  backtest_step: int | None = None  # defaults to horizon


def _peak_rss_bytes() -> int:
  # macOS reports bytes, Linux kilobytes.
  r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
  return int(r if r > 1 << 32 or os.uname().sysname == "Darwin" else r * 1024)


class Runtime:
  """Holds at most one loaded model and runs forecasts on it."""

  def __init__(self, models_dir: str):
    self.models_dir = models_dir
    self._lock = threading.RLock()
    self.forecaster: Any = None
    self.options: LoadOptions | None = None
    self.loaded_at: float | None = None
    self.load_seconds: float | None = None
    self.results: dict[str, dict[str, Any]] = {}
    self._result_order: list[str] = []

  # ---- status ----
  def status(self) -> dict[str, Any]:
    with self._lock:
      loaded = self.forecaster is not None
      info: dict[str, Any] = {"loaded": loaded, "peak_rss_bytes": _peak_rss_bytes()}
      if loaded and self.options:
        info.update(
          model_id=self.options.model_id,
          backend=self.options.backend,
          options=dataclasses.asdict(self.options),
          flags=self.current_flags(),
          supported_flags=self.supported_flags(),
          load_seconds=self.load_seconds,
          loaded_at=self.loaded_at,
        )
      try:
        import mlx.core as mx

        info["mlx_active_bytes"] = int(mx.get_active_memory())
      except Exception:  # noqa: BLE001 - optional
        pass
      return info

  def _flag_holder(self) -> Any:
    m = self.forecaster.model
    return m.config if self.options and self.options.backend == "mlx" else m

  def supported_flags(self) -> list[str]:
    """Flags the loaded backend actually reads (the MLX backend implements a subset)."""
    if self.forecaster is None:
      return []
    holder = self._flag_holder()
    return [k for k in RUNTIME_FLAGS if hasattr(holder, k)]

  def current_flags(self) -> dict[str, Any]:
    if self.forecaster is None:
      return {}
    holder = self._flag_holder()
    return {k: getattr(holder, k) for k in self.supported_flags()}

  # ---- load / unload ----
  def load(self, opts: LoadOptions) -> dict[str, Any]:
    path = _model_path(self.models_dir, opts.model_id)
    bad = set(opts.overrides) - set(RUNTIME_FLAGS)
    if bad:
      raise EngineError(f"Unknown model flags: {', '.join(sorted(bad))}")
    with self._lock:
      self.unload()
      t0 = time.time()
      if opts.backend == "mlx":
        try:
          from timesfm3.mlx import TimesFM3Forecaster as MlxForecaster
        except ImportError as e:
          raise EngineError(f"MLX backend unavailable: {e}") from e
        if not hasattr(MlxForecaster, "from_pretrained"):
          raise EngineError("MLX backend unavailable on this machine (Apple Silicon required).")
        if opts.overrides.get("use_frozen_running_stats"):
          raise EngineError("use_frozen_running_stats is only supported by the PyTorch backend.")
        fc = MlxForecaster.from_pretrained(
          path,
          compile=opts.compile,
          per_core_batch_size=opts.per_core_batch_size,
          max_context_length=min(opts.max_context_length, MAX_CONTEXT),
          local_files_only=True,
        )
      elif opts.backend in ("torch-mps", "torch-cpu"):
        import torch
        from timesfm3.torch import TimesFM3Forecaster as TorchForecaster

        device = "mps" if opts.backend == "torch-mps" else "cpu"
        if device == "mps" and not torch.backends.mps.is_available():
          raise EngineError("Metal (MPS) is not available to PyTorch on this machine.")
        fc = TorchForecaster.from_pretrained(
          path, device=device, per_core_batch_size=opts.per_core_batch_size, local_files_only=True
        )
      else:
        raise EngineError(f"Unknown backend '{opts.backend}'.")
      self.forecaster = fc
      self.options = opts
      self._apply_overrides(opts.overrides)
      self.load_seconds = time.time() - t0
      self.loaded_at = time.time()
      return self.status()

  def _apply_overrides(self, overrides: dict[str, Any]) -> None:
    if not overrides:
      return
    supported = set(self.supported_flags())
    defaults = {"use_iterative_cpm_revin": True, "use_frozen_running_stats": False}
    for k, v in list(overrides.items()):
      if k not in supported:
        if k in defaults and v != defaults[k]:
          raise EngineError(f"{k} can't be changed on the {self.options.backend} backend; use PyTorch.")
        overrides = {kk: vv for kk, vv in overrides.items() if kk != k}
    m = self.forecaster.model
    if self.options.backend == "mlx":
      m.config = dataclasses.replace(m.config, **{k: v for k, v in overrides.items() if hasattr(m.config, k)})
      m._compiled_forward = None  # re-trace with the new flags
    else:
      for k, v in overrides.items():
        setattr(m, k, v)
      if overrides.get("use_stitching") and not hasattr(m, "_stitching_extract_len"):
        m._stitching_extract_len = min(2 * m.input_patch_len, m.output_patch_len)

  def set_flags(self, overrides: dict[str, Any]) -> dict[str, Any]:
    with self._lock:
      if self.forecaster is None:
        raise EngineError("No model loaded.")
      bad = set(overrides) - set(RUNTIME_FLAGS)
      if bad:
        raise EngineError(f"Unknown model flags: {', '.join(sorted(bad))}")
      if self.options.backend == "mlx" and overrides.get("use_frozen_running_stats"):
        raise EngineError("use_frozen_running_stats is only supported by the PyTorch backend.")
      self._apply_overrides(overrides)
      self.options.overrides.update(overrides)
      return self.status()

  def unload(self) -> None:
    with self._lock:
      if self.forecaster is None:
        return
      backend = self.options.backend if self.options else ""
      self.forecaster = None
      self.options = None
      import gc

      gc.collect()
      if backend == "mlx":
        try:
          import mlx.core as mx

          mx.clear_cache()
        except Exception:  # noqa: BLE001
          pass
      elif backend == "torch-mps":
        try:
          import torch

          torch.mps.empty_cache()
        except Exception:  # noqa: BLE001
          pass

  # ---- raw prediction ----
  def predict(
    self,
    contexts: list[np.ndarray],
    horizon: int,
    opts: ForecastOptions,
    past_covs: list[np.ndarray | None] | None = None,
    future_covs: list[np.ndarray | None] | None = None,
  ) -> list[np.ndarray]:
    """Returns one (n_variates, horizon, 9) quantile array per context (1D inputs -> n_variates=1)."""
    with self._lock:
      if self.forecaster is None:
        raise EngineError("No model loaded. Pick a model in the top bar and press Load.")
      if horizon < 1:
        raise EngineError("Horizon must be at least 1.")
      if opts.padding_mode not in ("none", "edge"):
        raise EngineError("padding_mode must be 'none' or 'edge'.")
      outs = list(
        self.forecaster.predict_batch(
          contexts=contexts,
          horizon=horizon,
          past_only_covariates=past_covs,
          past_future_covariates=future_covs,
          return_quantiles=True,
          use_symmetric_averaging=opts.use_symmetric_averaging,
          make_positive=opts.make_positive,
          sort_quantiles=opts.sort_quantiles,
          use_znorm=opts.use_znorm,
          padding_mode=opts.padding_mode,
        )
      )
    result = []
    for o in outs:
      q = np.asarray(o.quantiles, dtype=np.float64)
      if q.ndim == 2:
        q = q[None]
      result.append(q)
    return result

  # ---- dataset forecast ----
  def forecast_groups(
    self,
    groups: list[data_lib.SeriesGroup],
    target_names: list[str],
    opts: ForecastOptions,
  ) -> dict[str, Any]:
    h = int(opts.horizon)
    if h < 1:
      raise EngineError("Horizon must be at least 1.")
    if h > 4096:
      raise EngineError("Horizon is limited to 4096 steps.")
    cap = MAX_CONTEXT
    if self.options:
      cap = min(cap, self.options.max_context_length)
    ctx_len = min(int(opts.context_length), cap) if opts.context_length else cap
    windows = max(1, int(opts.backtest_windows)) if opts.backtest else 1
    step = int(opts.backtest_step or h)
    warnings: list[str] = []

    # Build one query per (group, window[, target]).
    queries = []  # (group_idx, window_idx, target_rows, context, po, pf)
    for gi, g in enumerate(groups):
      n_hist = g.targets.shape[1]
      for w in range(windows):
        cutoff = n_hist - h - w * step if opts.backtest else n_hist
        if cutoff < 2:
          if opts.backtest:
            warnings.append(f"{g.key}: not enough history for backtest window {w + 1}; skipped.")
          continue
        start = max(0, cutoff - ctx_len)
        ctx = g.targets[:, start:cutoff]
        po = g.past_cov[:, start:cutoff] if g.past_cov is not None else None
        pf = None
        if g.future_cov is not None:
          avail = g.future_cov.shape[1] - cutoff
          if avail >= h:
            pf = g.future_cov[:, start : cutoff + h]
          elif opts.padding_mode == "edge":
            pf = g.future_cov[:, start:]
            pad = cutoff + h - g.future_cov.shape[1]
            pf = np.pad(pf, [(0, 0), (0, pad)], mode="edge")
            warnings.append(
              f"{g.key}: future covariates known for {max(avail, 0)} of {h} steps; "
              "the rest repeat the last known value (edge padding)."
            )
          else:
            raise EngineError(
              f"Future covariates for '{g.key}' are known for only {max(avail, 0)} step(s) after the history, "
              f"but the horizon is {h}. Add future rows to the file, lower the horizon, or set padding to 'edge'."
            )
        if opts.mode == "independent":
          for r in range(ctx.shape[0]):
            queries.append((gi, w, [r], ctx[r], po, pf, cutoff, start))
        else:
          queries.append((gi, w, list(range(ctx.shape[0])), ctx, po, pf, cutoff, start))
    if not queries:
      raise EngineError("Nothing to forecast: the series are too short for this horizon/backtest setting.")

    t0 = time.time()
    preds = self.predict(
      [q[3] for q in queries],
      h,
      opts,
      past_covs=[q[4] for q in queries] if any(q[4] is not None for q in queries) else None,
      future_covs=[q[5] for q in queries] if any(q[5] is not None for q in queries) else None,
    )
    elapsed = time.time() - t0

    # Assemble per group / target.
    per: dict[tuple[int, int, int], tuple[np.ndarray, int, int]] = {}
    for q, p in zip(queries, preds):
      gi, w, rows, _, _, _, cutoff, start = q
      for k, r in enumerate(rows):
        per[(gi, w, r)] = (p[k], cutoff, start)

    out_groups = []
    all_metrics: list[dict[str, float]] = []
    for gi, g in enumerate(groups):
      n_hist = g.targets.shape[1]
      times = g.times
      t_strings = [pd.Timestamp(t).isoformat() for t in times] if times is not None else None
      display_start = max(0, n_hist - max(ctx_len, 4 * h) - (windows - 1) * step - h, n_hist - 5000)
      targets_out = []
      for r, name in enumerate(target_names):
        y = g.targets[r]
        wins = []
        for w in range(windows):
          if (gi, w, r) not in per:
            continue
          qarr, cutoff, start = per[(gi, w, r)]
          f_idx = list(range(cutoff, cutoff + h))
          f_time = data_lib.future_timestamps(times, cutoff, h, g.frequency) if times is not None else None
          actual = y[cutoff : cutoff + h] if opts.backtest else None
          metrics = compute_metrics(actual, qarr, y[start:cutoff]) if actual is not None else None
          if metrics:
            all_metrics.append(metrics)
          wins.append(
            {
              "window": w,
              "cutoff_index": cutoff,
              "context_start_index": start,
              "index": f_idx,
              "time": f_time,
              "median": _clean(qarr[:, 4]),
              "quantiles": [_clean(qarr[:, j]) for j in range(qarr.shape[1])],
              "actual": _clean(actual) if actual is not None else None,
              "metrics": metrics,
            }
          )
        targets_out.append(
          {
            "name": name,
            "history": {
              "index": list(range(display_start, n_hist)),
              "time": t_strings[display_start:n_hist] if t_strings else None,
              "value": _clean(y[display_start:n_hist]),
            },
            "windows": wins,
            "metrics": _mean_metrics([w_["metrics"] for w_ in wins if w_["metrics"]]),
          }
        )
      out_groups.append(
        {"key": g.key, "frequency": g.frequency, "n_history": n_hist, "targets": targets_out}
      )

    result_id = uuid.uuid4().hex[:12]
    result = {
      "result_id": result_id,
      "model_id": self.options.model_id if self.options else None,
      "backend": self.options.backend if self.options else None,
      "flags": self.current_flags(),
      "horizon": h,
      "context_length": ctx_len,
      "mode": opts.mode,
      "backtest": opts.backtest,
      "quantile_levels": QUANTILE_LEVELS,
      "elapsed_seconds": elapsed,
      "num_queries": len(queries),
      "groups": out_groups,
      "metrics": _mean_metrics(all_metrics),
      "warnings": warnings,
      "options": dataclasses.asdict(opts),
    }
    self._remember(result)
    return result

  def _remember(self, result: dict[str, Any]) -> None:
    self.results[result["result_id"]] = result
    self._result_order.append(result["result_id"])
    while len(self._result_order) > 30:
      self.results.pop(self._result_order.pop(0), None)


# --------------------------------------------------------------------------- metrics


def _clean(a: np.ndarray | None) -> list[float | None] | None:
  if a is None:
    return None
  return [float(x) if np.isfinite(x) else None for x in np.asarray(a, dtype=np.float64)]


def compute_metrics(actual: np.ndarray, q: np.ndarray, history: np.ndarray) -> dict[str, float] | None:
  """Point + probabilistic accuracy of one forecast window. q: (h, 9)."""
  y = np.asarray(actual, dtype=np.float64)
  mask = np.isfinite(y)
  if mask.sum() == 0:
    return None
  y = y[mask]
  q = np.asarray(q, dtype=np.float64)[mask]
  med = q[:, 4]
  err = med - y
  mae = float(np.mean(np.abs(err)))
  rmse = float(np.sqrt(np.mean(err**2)))
  nz = np.abs(y) > 1e-12
  mape = float(np.mean(np.abs(err[nz] / y[nz])) * 100) if nz.any() else float("nan")
  denom = np.abs(y) + np.abs(med)
  smape = float(np.mean(np.where(denom > 0, 2 * np.abs(err) / np.where(denom > 0, denom, 1), 0)) * 100)
  hist = np.asarray(history, dtype=np.float64)
  hist = hist[np.isfinite(hist)]
  naive_scale = float(np.mean(np.abs(np.diff(hist)))) if hist.size > 1 else float("nan")
  mase = mae / naive_scale if naive_scale and naive_scale > 0 else float("nan")
  # Naive forecast (repeat last value) for a skill score.
  naive_mae = float(np.mean(np.abs(y - hist[-1]))) if hist.size else float("nan")
  skill = 1 - mae / naive_mae if naive_mae and naive_mae > 0 else float("nan")
  levels = np.asarray(QUANTILE_LEVELS)[None, :]
  diff = y[:, None] - q
  pinball = np.maximum(levels * diff, (levels - 1) * diff)
  scale = np.sum(np.abs(y))
  wql = float(2 * pinball.sum(axis=0).mean() / scale) if scale > 0 else float("nan")
  cov80 = float(np.mean((y >= q[:, 0]) & (y <= q[:, 8])) * 100)
  cov40 = float(np.mean((y >= q[:, 2]) & (y <= q[:, 6])) * 100)
  return {
    "mae": mae,
    "rmse": rmse,
    "mape": mape,
    "smape": smape,
    "mase": mase,
    "wql": wql,
    "coverage_80": cov80,
    "coverage_40": cov40,
    "naive_mae": naive_mae,
    "skill_vs_naive": skill,
  }


def _mean_metrics(rows: list[dict[str, float]]) -> dict[str, float | None] | None:
  if not rows:
    return None
  out: dict[str, float | None] = {}
  for k in rows[0]:
    vals = [r[k] for r in rows if r.get(k) is not None and math.isfinite(r[k])]
    out[k] = float(np.mean(vals)) if vals else None
  return out


# --------------------------------------------------------------------------- export


def export_result(result: dict[str, Any], path: str) -> str:
  rows = []
  levels = result["quantile_levels"]
  for g in result["groups"]:
    for t in g["targets"]:
      for w in t["windows"]:
        for i, idx in enumerate(w["index"]):
          row = {
            "series": g["key"],
            "target": t["name"],
            "window": w["window"],
            "step": i + 1,
            "index": idx,
            "timestamp": w["time"][i] if w["time"] else None,
            "forecast_median": w["median"][i],
          }
          for j, lv in enumerate(levels):
            row[f"p{int(round(lv * 100))}"] = w["quantiles"][j][i]
          if w["actual"] is not None:
            row["actual"] = w["actual"][i]
          rows.append(row)
  df = pd.DataFrame(rows)
  if df["timestamp"].isna().all():
    df = df.drop(columns=["timestamp"])
  if len(result["groups"]) == 1:
    df = df.drop(columns=["series"])
  if not result["backtest"]:
    df = df.drop(columns=["window"])
  ext = os.path.splitext(path)[1].lower()
  if ext in (".xlsx", ".xlsm"):
    with pd.ExcelWriter(path, engine="openpyxl") as xw:
      df.to_excel(xw, sheet_name="forecast", index=False)
      summary = {
        "model": result["model_id"],
        "backend": result["backend"],
        "horizon": result["horizon"],
        "context_length": result["context_length"],
        "mode": result["mode"],
        "backtest": result["backtest"],
        **{f"option.{k}": v for k, v in result["options"].items()},
        **{f"flag.{k}": v for k, v in result["flags"].items()},
        **{f"metric.{k}": v for k, v in (result["metrics"] or {}).items()},
      }
      pd.DataFrame({"setting": list(summary), "value": [str(v) for v in summary.values()]}).to_excel(
        xw, sheet_name="run", index=False
      )
  else:
    df.to_csv(path, index=False)
  return path
