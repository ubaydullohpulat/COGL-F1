"""Local HTTP API of the Forecast Studio engine. The macOS app is a client of this server; so can be scripts."""

from __future__ import annotations

import dataclasses
import os
import platform
import sys
from typing import Any

import numpy as np
from fastapi import FastAPI, File, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from . import __version__
from . import data as data_lib
from . import finetune as ft_lib
from . import runtime as rt
from .jobs import JobRegistry


class LoadRequest(BaseModel):
  model_id: str
  backend: str = "mlx"
  compile: bool = True
  per_core_batch_size: int = 32
  max_context_length: int = rt.MAX_CONTEXT
  overrides: dict[str, Any] = Field(default_factory=dict)


class FlagsRequest(BaseModel):
  overrides: dict[str, Any]


class OpenPathRequest(BaseModel):
  path: str


class SeriesSelection(BaseModel):
  dataset_id: str
  sheet: str | None = None
  time_column: str | None = None
  id_column: str | None = None
  targets: list[str]
  past_covariates: list[str] = Field(default_factory=list)
  future_covariates: list[str] = Field(default_factory=list)
  fill_method: str = "interpolate"
  start_row: int | None = None
  end_row: int | None = None


class ForecastParams(BaseModel):
  horizon: int = 32
  context_length: int | None = None
  mode: str = "joint"
  use_symmetric_averaging: bool = False
  use_znorm: bool = False
  make_positive: bool = False
  sort_quantiles: bool = True
  padding_mode: str = "none"
  backtest: bool = False
  backtest_windows: int = 1
  backtest_step: int | None = None


class ForecastRequest(BaseModel):
  data: SeriesSelection
  params: ForecastParams = Field(default_factory=ForecastParams)


class RawForecastRequest(BaseModel):
  """Forecast plain arrays: each input is a list (univariate) or list of lists (variates x time)."""

  inputs: list[Any]
  horizon: int
  past_covariates: list[Any] | None = None
  future_covariates: list[Any] | None = None
  params: ForecastParams = Field(default_factory=ForecastParams)


class ExportRequest(BaseModel):
  result_id: str
  path: str


class FinetuneRequest(BaseModel):
  data: SeriesSelection
  config: dict[str, Any]


def create_app(models_dir: str) -> FastAPI:
  os.makedirs(models_dir, exist_ok=True)
  app = FastAPI(title="Forecast Studio Engine", version=__version__)
  runtime = rt.Runtime(models_dir)
  datasets = data_lib.DatasetStore()
  jobs = JobRegistry()
  app.state.runtime = runtime

  @app.exception_handler(data_lib.DataError)
  async def _data_error(_: Request, exc: data_lib.DataError):
    return JSONResponse(status_code=400, content={"detail": str(exc)})

  @app.exception_handler(rt.EngineError)
  async def _engine_error(_: Request, exc: rt.EngineError):
    return JSONResponse(status_code=400, content={"detail": str(exc)})

  # ------------------------------------------------------------------ system
  @app.get("/health")
  def health():
    info: dict[str, Any] = {
      "ok": True,
      "version": __version__,
      "python": sys.version.split()[0],
      "platform": platform.platform(),
      "machine": platform.machine(),
      "models_dir": models_dir,
      "backends": {},
    }
    try:
      import timesfm3  # noqa: F401
      from importlib.metadata import version

      info["timesfm_version"] = version("timesfm")
    except Exception as e:  # noqa: BLE001
      info["timesfm_error"] = str(e)
    try:
      import mlx.core as mx

      info["backends"]["mlx"] = {"available": True, "device": str(mx.default_device())}
    except Exception as e:  # noqa: BLE001
      info["backends"]["mlx"] = {"available": False, "error": str(e)}
    try:
      import torch

      info["backends"]["torch"] = {"available": True, "version": torch.__version__, "mps": torch.backends.mps.is_available()}
    except Exception as e:  # noqa: BLE001
      info["backends"]["torch"] = {"available": False, "error": str(e)}
    return info

  @app.post("/shutdown")
  def shutdown():
    os._exit(0)  # the app restarts us when needed

  # ------------------------------------------------------------------ models
  @app.get("/models")
  def models():
    return {"models": rt.list_models(models_dir), "models_dir": models_dir}

  @app.delete("/models/{model_id}")
  def delete_model(model_id: str):
    st = runtime.status()
    if st.get("loaded") and st.get("model_id") == model_id:
      runtime.unload()
    rt.delete_model(models_dir, model_id)
    return {"deleted": model_id}

  @app.get("/status")
  def status():
    return runtime.status()

  @app.post("/load")
  def load(req: LoadRequest):
    return runtime.load(rt.LoadOptions(**req.model_dump()))

  @app.post("/unload")
  def unload():
    runtime.unload()
    return runtime.status()

  @app.post("/flags")
  def flags(req: FlagsRequest):
    return runtime.set_flags(req.overrides)

  # ------------------------------------------------------------------ datasets
  def _describe(ds: data_lib.Dataset) -> dict[str, Any]:
    return {
      "dataset_id": ds.id,
      "name": ds.name,
      "path": ds.path,
      "sheets": [data_lib.describe_sheet(s) for s in ds.sheets.values()],
    }

  @app.post("/datasets/open")
  def open_dataset(req: OpenPathRequest):
    return _describe(datasets.add(data_lib.load_file(path=os.path.expanduser(req.path))))

  @app.post("/datasets/upload")
  async def upload_dataset(file: UploadFile = File(...)):
    content = await file.read()
    return _describe(datasets.add(data_lib.load_file(content=content, filename=file.filename)))

  @app.get("/datasets/{dataset_id}")
  def get_dataset(dataset_id: str):
    return _describe(datasets.get(dataset_id))

  def _groups(sel: SeriesSelection) -> tuple[data_lib.Dataset, list[data_lib.SeriesGroup]]:
    ds = datasets.get(sel.dataset_id)
    sheet = ds.sheet(sel.sheet)
    spec = data_lib.SeriesSpec(
      time_column=sel.time_column,
      id_column=sel.id_column,
      targets=sel.targets,
      past_covariates=sel.past_covariates,
      future_covariates=sel.future_covariates,
      fill_method=sel.fill_method,
      start_row=sel.start_row,
      end_row=sel.end_row,
    )
    return ds, data_lib.extract_groups(sheet, spec)

  # ------------------------------------------------------------------ forecasting
  @app.post("/forecast")
  def forecast(req: ForecastRequest):
    _, groups = _groups(req.data)
    return runtime.forecast_groups(groups, req.data.targets, rt.ForecastOptions(**req.params.model_dump()))

  @app.post("/v1/forecast")
  def raw_forecast(req: RawForecastRequest):
    def arr(x):
      return None if x is None else np.asarray(x, dtype=np.float32)

    n = len(req.inputs)
    ctx = [arr(x) for x in req.inputs]
    po = [arr(x) for x in req.past_covariates] if req.past_covariates else None
    pf = [arr(x) for x in req.future_covariates] if req.future_covariates else None
    if (po and len(po) != n) or (pf and len(pf) != n):
      raise HTTPException(400, "Covariate lists must have one entry per input.")
    opts = rt.ForecastOptions(**{**req.params.model_dump(), "horizon": req.horizon})
    preds = runtime.predict(ctx, req.horizon, opts, po, pf)
    out = []
    for c, q in zip(ctx, preds):
      qs = np.transpose(q, (0, 2, 1))  # (u, 9, h)
      if c.ndim == 1:
        out.append({"median": q[0, :, 4].tolist(), "quantiles": qs[0].tolist()})
      else:
        out.append({"median": q[:, :, 4].tolist(), "quantiles": qs.tolist()})
    return {"quantile_levels": rt.QUANTILE_LEVELS, "forecasts": out, "model_id": runtime.status().get("model_id")}

  @app.post("/export")
  def export(req: ExportRequest):
    result = runtime.results.get(req.result_id)
    if result is None:
      raise HTTPException(404, "Forecast result expired; run the forecast again.")
    return {"path": rt.export_result(result, os.path.expanduser(req.path))}

  # ------------------------------------------------------------------ fine-tuning
  @app.post("/finetune")
  def finetune(req: FinetuneRequest):
    ds, groups = _groups(req.data)
    known = {f.name for f in dataclasses.fields(ft_lib.FinetuneConfig)}
    unknown = set(req.config) - known
    if unknown:
      raise HTTPException(400, f"Unknown fine-tuning options: {', '.join(sorted(unknown))}")
    cfg = ft_lib.FinetuneConfig(**req.config)
    rt._model_path(models_dir, cfg.base_model_id)  # fail fast if the base model is missing
    info = {
      "file": ds.name,
      "sheet": req.data.sheet,
      "targets": req.data.targets,
      "past_covariates": req.data.past_covariates,
      "future_covariates": req.data.future_covariates,
      "id_column": req.data.id_column,
      "series": len(groups),
    }
    job = jobs.start(
      "finetune",
      f"Fine-tune {cfg.base_model_id}",
      lambda j: ft_lib.run_finetune(j, models_dir, groups, cfg, info),
    )
    return job.snapshot()

  @app.get("/jobs")
  def list_jobs():
    return {"jobs": [j.snapshot(log_tail=5) for j in jobs.list()]}

  @app.get("/jobs/{job_id}")
  def get_job(job_id: str, log_tail: int = 300):
    job = jobs.get(job_id)
    if job is None:
      raise HTTPException(404, "Job not found")
    return job.snapshot(log_tail=log_tail)

  @app.post("/jobs/{job_id}/cancel")
  def cancel_job(job_id: str):
    job = jobs.get(job_id)
    if job is None:
      raise HTTPException(404, "Job not found")
    job.cancel()
    return job.snapshot()

  @app.post("/jobs/{job_id}/finish")
  def finish_job(job_id: str):
    job = jobs.get(job_id)
    if job is None:
      raise HTTPException(404, "Job not found")
    job.finish()
    return job.snapshot()

  return app
