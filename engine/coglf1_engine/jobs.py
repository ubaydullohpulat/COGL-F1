"""Background jobs (fine-tuning, long loads) with progress, logs and cancellation."""

from __future__ import annotations

import math
import threading
import time
import traceback
import uuid
from collections import deque
from typing import Any, Callable


class Cancelled(Exception):
  """Raised inside a job when the user asked it to stop."""


def _finite(value: Any) -> Any:
  """Replaces NaN and infinity with None. JSON has neither, so one of them would fail every poll of the job."""
  if isinstance(value, float):
    return value if math.isfinite(value) else None
  if isinstance(value, dict):
    return {k: _finite(v) for k, v in value.items()}
  if isinstance(value, (list, tuple)):
    return [_finite(v) for v in value]
  return value


class Job:
  def __init__(self, kind: str, title: str):
    self.id = uuid.uuid4().hex[:12]
    self.kind = kind
    self.title = title
    self.status = "queued"  # queued | running | completed | failed | cancelled
    self.progress = 0.0
    self.message = ""
    self.created = time.time()
    self.started: float | None = None
    self.finished: float | None = None
    self.logs: deque[str] = deque(maxlen=2000)
    self.metrics: list[dict[str, Any]] = []
    self.result: Any = None
    self.error: str | None = None
    self._cancel = threading.Event()
    self._finish = threading.Event()
    self._lock = threading.Lock()

  # ---- called from the worker ----
  def log(self, line: str) -> None:
    stamp = time.strftime("%H:%M:%S")
    with self._lock:
      self.logs.append(f"[{stamp}] {line}")

  def update(self, progress: float | None = None, message: str | None = None) -> None:
    with self._lock:
      if progress is not None:
        self.progress = max(0.0, min(1.0, float(progress)))
      if message is not None:
        self.message = message

  def add_metric(self, **row: Any) -> None:
    with self._lock:
      self.metrics.append(row)

  def check_cancel(self) -> None:
    if self._cancel.is_set():
      raise Cancelled()

  @property
  def cancel_requested(self) -> bool:
    return self._cancel.is_set()

  @property
  def finish_requested(self) -> bool:
    return self._finish.is_set()

  # ---- called from the API ----
  def cancel(self) -> None:
    self._cancel.set()

  def finish(self) -> None:
    """Ask the job to stop early but keep (save) what it has so far."""
    self._finish.set()

  def snapshot(self, log_tail: int = 200) -> dict[str, Any]:
    with self._lock:
      return {
        "id": self.id,
        "kind": self.kind,
        "title": self.title,
        "status": self.status,
        "progress": self.progress,
        "message": self.message,
        "created": self.created,
        "started": self.started,
        "finished": self.finished,
        "logs": list(self.logs)[-log_tail:],
        "metrics": _finite(self.metrics),
        "result": _finite(self.result),
        "error": self.error,
      }


class JobRegistry:
  def __init__(self) -> None:
    self._jobs: dict[str, Job] = {}
    self._lock = threading.Lock()

  def start(self, kind: str, title: str, fn: Callable[[Job], Any]) -> Job:
    job = Job(kind, title)
    with self._lock:
      self._jobs[job.id] = job

    def run() -> None:
      job.status = "running"
      job.started = time.time()
      try:
        job.result = fn(job)
        job.status = "cancelled" if job.cancel_requested else "completed"
        job.progress = 1.0 if job.status == "completed" else job.progress
      except Cancelled:
        job.status = "cancelled"
        job.log("Cancelled by user.")
      except Exception as e:  # noqa: BLE001 - surface every failure to the UI
        job.status = "failed"
        job.error = f"{type(e).__name__}: {e}"
        job.log(traceback.format_exc())
      finally:
        job.finished = time.time()

    threading.Thread(target=run, name=f"job-{job.id}", daemon=True).start()
    return job

  def get(self, job_id: str) -> Job | None:
    return self._jobs.get(job_id)

  def list(self) -> list[Job]:
    return sorted(self._jobs.values(), key=lambda j: j.created, reverse=True)
