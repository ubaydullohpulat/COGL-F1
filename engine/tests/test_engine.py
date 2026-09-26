"""End-to-end engine tests on a tiny random-weight TimesFM 3 checkpoint (no download needed).

Run from the repo root:  .venv/bin/python -m pytest engine/tests -q
"""

from __future__ import annotations

import json
import os
import sys
import time

import numpy as np
import pandas as pd
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from fastapi.testclient import TestClient  # noqa: E402

from coglf1_engine.server import create_app  # noqa: E402


def _make_tiny_model(path: str) -> None:
  import torch
  from timesfm3.torch import configs as C
  from timesfm3.torch import model as M

  torch.manual_seed(0)
  tc = C.StackedTransformersConfig(
    num_layers=2,
    transformer=C.TransformerConfig(
      model_dims=64, hidden_dims=64, num_heads=4, attention_norm="rms", feedforward_norm="rms",
      qk_norm="rms", use_bias=False, use_rope_seq=True, use_rope_var=False, ff_activation="relu",
      deterministic=True,
    ),
  )
  rc = C.ResidualBlockConfig(hidden_dims=64, output_dims=64, use_bias=False, activation="relu")
  M.TimesFM3Torch(residual_block_config=rc, transformer_config=tc).save_pretrained(path)
  with open(os.path.join(path, "cogl_meta.json"), "w") as f:
    json.dump({"kind": "base", "source": "test", "display_name": "Tiny test model"}, f)


@pytest.fixture(scope="module")
def env(tmp_path_factory):
  root = tmp_path_factory.mktemp("engine")
  models = root / "models"
  models.mkdir()
  _make_tiny_model(str(models / "tiny"))

  # Wide daily CSV: 2 targets, a past-only covariate, a future covariate known 20 steps ahead.
  n, fut = 400, 20
  t = np.arange(n + fut)
  df = pd.DataFrame(
    {
      "date": pd.date_range("2024-01-01", periods=n + fut, freq="D").strftime("%Y-%m-%d"),
      "sales": np.r_[100 + 10 * np.sin(t[:n] / 7) + np.random.default_rng(0).normal(0, 1, n), [np.nan] * fut],
      "visits": np.r_[50 + 5 * np.cos(t[:n] / 7), [np.nan] * fut],
      "temperature": np.r_[20 + 3 * np.sin(t[:n] / 30), [np.nan] * fut],
      "promo": (t % 14 == 0).astype(float),
    }
  )
  df.loc[10, "sales"] = np.nan  # a gap to interpolate
  csv_path = root / "shop.csv"
  df.to_csv(csv_path, index=False)

  # Long-format Excel with an id column and two sheets.
  rows = []
  for sid in ("A", "B", "C"):
    for i, d in enumerate(pd.date_range("2020-01-01", periods=120, freq="MS")):
      rows.append({"store": sid, "month": d, "revenue": 1000 + 50 * i + (ord(sid) - 64) * 100})
  xlsx_path = root / "stores.xlsx"
  with pd.ExcelWriter(xlsx_path) as xw:
    pd.DataFrame(rows).to_excel(xw, sheet_name="long", index=False)
    pd.DataFrame({"x": [1, 2, 3]}).to_excel(xw, sheet_name="tiny", index=False)

  client = TestClient(create_app(str(models)))
  return {"client": client, "csv": str(csv_path), "xlsx": str(xlsx_path), "root": root, "models": models}


def _ok(r):
  assert r.status_code == 200, r.text
  return r.json()


def test_health_and_models(env):
  c = env["client"]
  h = _ok(c.get("/health"))
  assert h["backends"]["mlx"]["available"]
  assert h["backends"]["torch"]["available"]
  models = _ok(c.get("/models"))["models"]
  assert [m["id"] for m in models] == ["tiny"]
  assert models[0]["architecture"]["num_layers"] == 2


def test_forecast_requires_model(env):
  c = env["client"]
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  r = c.post("/forecast", json={"data": {"dataset_id": ds["dataset_id"], "targets": ["sales"]}})
  assert r.status_code == 400 and "No model loaded" in r.json()["detail"]


def test_dataset_detection(env):
  c = env["client"]
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  sheet = ds["sheets"][0]
  assert sheet["time_column"] == "date"
  assert sheet["frequency"] == "D"
  assert {col["name"] for col in sheet["columns"] if col["numeric"]} == {"sales", "visits", "temperature", "promo"}

  x = _ok(c.post("/datasets/open", json={"path": env["xlsx"]}))
  names = [s["name"] for s in x["sheets"]]
  assert names == ["long", "tiny"]
  long = x["sheets"][0]
  assert long["time_column"] == "month"
  assert long["id_candidates"] == ["store"]


@pytest.mark.parametrize("backend", ["mlx", "torch-cpu", "torch-mps"])
def test_forecast_backends(env, backend):
  c = env["client"]
  st = _ok(c.post("/load", json={"model_id": "tiny", "backend": backend}))
  assert st["loaded"] and st["backend"] == backend
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  res = _ok(
    c.post(
      "/forecast",
      json={
        "data": {
          "dataset_id": ds["dataset_id"],
          "time_column": "date",
          "targets": ["sales", "visits"],
          "past_covariates": ["temperature"],
          "future_covariates": ["promo"],
        },
        "params": {"horizon": 20, "context_length": 256},
      },
    )
  )
  g = res["groups"][0]
  assert len(g["targets"]) == 2
  w = g["targets"][0]["windows"][0]
  assert len(w["median"]) == 20 and len(w["quantiles"]) == 9
  assert w["time"][0] == "2025-02-04T00:00:00"  # day after the last observed row
  assert w["cutoff_index"] == 400
  q = np.array(w["quantiles"])
  assert np.all(np.diff(q, axis=0) >= -1e-4), "quantiles must be sorted"
  _ok(c.post("/unload"))


def test_backends_agree(env):
  c = env["client"]
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  body = {
    "data": {"dataset_id": ds["dataset_id"], "time_column": "date", "targets": ["sales", "visits"]},
    "params": {"horizon": 30},
  }
  meds = {}
  for backend in ("mlx", "torch-cpu"):
    _ok(c.post("/load", json={"model_id": "tiny", "backend": backend}))
    meds[backend] = np.array(_ok(c.post("/forecast", json=body))["groups"][0]["targets"][1]["windows"][0]["median"])
  assert np.allclose(meds["mlx"], meds["torch-cpu"], rtol=1e-3, atol=1e-3)


def test_future_covariate_horizon_guard(env):
  c = env["client"]
  _ok(c.post("/load", json={"model_id": "tiny", "backend": "mlx"}))
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  body = {
    "data": {"dataset_id": ds["dataset_id"], "time_column": "date", "targets": ["sales"], "future_covariates": ["promo"]},
    "params": {"horizon": 40},
  }
  r = c.post("/forecast", json=body)
  assert r.status_code == 400 and "known for only 20" in r.json()["detail"]
  body["params"]["padding_mode"] = "edge"
  res = _ok(c.post("/forecast", json=body))
  assert len(res["groups"][0]["targets"][0]["windows"][0]["median"]) == 40
  assert res["warnings"]


def test_all_forecast_flags(env):
  c = env["client"]
  _ok(c.post("/load", json={"model_id": "tiny", "backend": "mlx", "compile": False, "overrides": {"use_stitching": False}}))
  st = _ok(c.get("/status"))
  assert st["flags"]["use_stitching"] is False
  _ok(c.post("/flags", json={"overrides": {"use_linear_detrending": False, "linear_detrending_threshold": 0.3}}))
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  for params in (
    {"use_symmetric_averaging": True},
    {"use_znorm": True},
    {"make_positive": True},
    {"sort_quantiles": False},
    {"mode": "independent"},
  ):
    res = _ok(
      c.post(
        "/forecast",
        json={"data": {"dataset_id": ds["dataset_id"], "targets": ["sales", "visits"]}, "params": {"horizon": 12, **params}},
      )
    )
    assert res["flags"]["use_linear_detrending"] is False
    assert len(res["groups"][0]["targets"]) == 2
  r = c.post("/flags", json={"overrides": {"use_frozen_running_stats": True}})
  assert r.status_code == 400  # MLX doesn't implement it


def test_backtest_and_export(env):
  c = env["client"]
  _ok(c.post("/load", json={"model_id": "tiny", "backend": "mlx"}))
  x = _ok(c.post("/datasets/open", json={"path": env["xlsx"]}))
  res = _ok(
    c.post(
      "/forecast",
      json={
        "data": {"dataset_id": x["dataset_id"], "sheet": "long", "time_column": "month", "id_column": "store", "targets": ["revenue"]},
        "params": {"horizon": 6, "backtest": True, "backtest_windows": 3},
      },
    )
  )
  assert [g["key"] for g in res["groups"]] == ["A", "B", "C"]
  t = res["groups"][0]["targets"][0]
  assert len(t["windows"]) == 3
  assert t["windows"][0]["cutoff_index"] == 114 and t["windows"][2]["cutoff_index"] == 102
  assert t["windows"][0]["actual"] is not None
  assert t["windows"][0]["time"][0].startswith("2029-07-01")
  for k in ("mae", "rmse", "mape", "smape", "mase", "wql", "coverage_80", "skill_vs_naive"):
    assert k in res["metrics"]

  for ext in ("csv", "xlsx"):
    out = env["root"] / f"out.{ext}"
    _ok(c.post("/export", json={"result_id": res["result_id"], "path": str(out)}))
    df = pd.read_csv(out) if ext == "csv" else pd.read_excel(out, sheet_name="forecast")
    assert len(df) == 3 * 3 * 6
    assert {"series", "target", "p10", "p90", "actual", "forecast_median", "timestamp"} <= set(df.columns)


def test_raw_api(env):
  c = env["client"]
  _ok(c.post("/load", json={"model_id": "tiny", "backend": "mlx"}))
  res = _ok(
    c.post(
      "/v1/forecast",
      json={"inputs": [list(np.sin(np.arange(100) / 5)), [list(range(64)), list(range(64, 128))]], "horizon": 8},
    )
  )
  assert len(res["forecasts"][0]["median"]) == 8
  assert np.array(res["forecasts"][1]["quantiles"]).shape == (2, 9, 8)


@pytest.mark.parametrize("method", ["lora", "last_layers", "head", "full"])
def test_finetune(env, method):
  c = env["client"]
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  job = _ok(
    c.post(
      "/finetune",
      json={
        "data": {
          "dataset_id": ds["dataset_id"],
          "time_column": "date",
          "targets": ["sales", "visits"],
          "past_covariates": ["temperature"],
          "future_covariates": ["promo"],
        },
        "config": {
          "base_model_id": "tiny",
          "output_name": f"tiny {method}",
          "context_length": 128,
          "horizon": 16,
          "method": method,
          "train_last_layers": 1,
          "epochs": 2,
          "windows_per_epoch": 64,
          "batch_size": 8,
          "learning_rate": 1e-3,
          "device": "mps",
        },
      },
    )
  )
  for _ in range(600):
    snap = _ok(c.get(f"/jobs/{job['id']}"))
    if snap["status"] in ("completed", "failed", "cancelled"):
      break
    time.sleep(0.2)
  assert snap["status"] == "completed", "\n".join(snap["logs"]) + str(snap["error"])
  mid = snap["result"]["model_id"]
  assert mid == f"tiny-{method}"
  assert any(m["kind"] == "val" and m["epoch"] == 0 for m in snap["metrics"])
  assert any(m["kind"] == "train" for m in snap["metrics"])
  models = {m["id"]: m for m in _ok(c.get("/models"))["models"]}
  assert models[mid]["kind"] == "finetuned"
  # The merged checkpoint loads in MLX (no LoRA tensors left behind) and forecasts.
  _ok(c.post("/load", json={"model_id": mid, "backend": "mlx"}))
  res = _ok(
    c.post("/forecast", json={"data": {"dataset_id": ds["dataset_id"], "targets": ["sales"]}, "params": {"horizon": 5}})
  )
  assert len(res["groups"][0]["targets"][0]["windows"][0]["median"]) == 5
  _ok(c.delete(f"/models/{mid}"))


def test_finetune_cancel(env):
  c = env["client"]
  ds = _ok(c.post("/datasets/open", json={"path": env["csv"]}))
  job = _ok(
    c.post(
      "/finetune",
      json={
        "data": {"dataset_id": ds["dataset_id"], "targets": ["sales"]},
        "config": {"base_model_id": "tiny", "horizon": 16, "context_length": 64, "epochs": 50, "windows_per_epoch": 4096, "device": "cpu"},
      },
    )
  )
  time.sleep(1.0)
  _ok(c.post(f"/jobs/{job['id']}/cancel"))
  for _ in range(100):
    snap = _ok(c.get(f"/jobs/{job['id']}"))
    if snap["status"] != "running":
      break
    time.sleep(0.2)
  assert snap["status"] == "cancelled"
  assert [m["id"] for m in _ok(c.get("/models"))["models"]] == ["tiny"]
