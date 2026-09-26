"""Loading CSV / Excel files and turning columns into model-ready series."""

from __future__ import annotations

import csv
import dataclasses
import io
import os
import threading
import uuid
from typing import Any

import numpy as np
import pandas as pd

SUPPORTED_EXTENSIONS = (".csv", ".tsv", ".txt", ".xlsx", ".xlsm", ".xls")

_TIME_NAME_HINTS = ("date", "time", "timestamp", "datetime", "ds", "day", "month", "week", "period", "year")


def _is_text(s: pd.Series) -> bool:
  """Object or string dtype (pandas 3 infers a dedicated `str` dtype for text columns)."""
  return s.dtype == object or pd.api.types.is_string_dtype(s)


class DataError(ValueError):
  """A user-facing problem with the uploaded data or column selection."""


@dataclasses.dataclass
class Sheet:
  name: str
  frame: pd.DataFrame
  time_column: str | None
  frequency: str | None


@dataclasses.dataclass
class Dataset:
  id: str
  name: str
  path: str | None
  sheets: dict[str, Sheet]

  def sheet(self, name: str | None) -> Sheet:
    if name is None or name == "":
      return next(iter(self.sheets.values()))
    if name not in self.sheets:
      raise DataError(f"Sheet '{name}' not found in {self.name}.")
    return self.sheets[name]


# --------------------------------------------------------------------------- parsing


def _sniff_delimiter(sample: str, default: str) -> str:
  try:
    return csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
  except csv.Error:
    return default


def _read_text_table(raw: bytes, ext: str) -> pd.DataFrame:
  text_sample = raw[:65536].decode("utf-8", errors="replace")
  delimiter = _sniff_delimiter(text_sample, "\t" if ext == ".tsv" else ",")
  # European CSVs use ';' with ',' decimals.
  decimal = "," if delimiter == ";" else "."
  return pd.read_csv(io.BytesIO(raw), sep=delimiter, decimal=decimal, encoding_errors="replace")


def _clean_frame(df: pd.DataFrame) -> pd.DataFrame:
  df = df.dropna(axis=0, how="all").dropna(axis=1, how="all")
  df.columns = [str(c).strip() if str(c).strip() else f"column_{i + 1}" for i, c in enumerate(df.columns)]
  # De-duplicate column names.
  seen: dict[str, int] = {}
  cols = []
  for c in df.columns:
    if c in seen:
      seen[c] += 1
      cols.append(f"{c}.{seen[c]}")
    else:
      seen[c] = 0
      cols.append(c)
  df.columns = cols
  # Coerce text columns that are really numbers ("1,234", " 5 ").
  for c in df.columns:
    if _is_text(df[c]):
      s = df[c].astype(str).str.replace(",", "", regex=False).str.strip()
      num = pd.to_numeric(s.replace({"": np.nan, "nan": np.nan, "None": np.nan}), errors="coerce")
      non_null = df[c].notna().sum()
      if non_null and num.notna().sum() >= 0.95 * non_null:
        df[c] = num
  return df.reset_index(drop=True)


def _detect_time_column(df: pd.DataFrame) -> str | None:
  best: tuple[int, str] | None = None
  for i, c in enumerate(df.columns):
    s = df[c]
    if pd.api.types.is_datetime64_any_dtype(s):
      score = 100 - i
    elif _is_text(s):
      sample = s.dropna().astype(str).head(200)
      if sample.empty:
        continue
      parsed = pd.to_datetime(sample, errors="coerce", format="mixed")
      if parsed.notna().mean() < 0.9:
        continue
      score = 80 - i
    elif pd.api.types.is_integer_dtype(s) and any(h in c.lower() for h in ("year",)):
      score = 40 - i
    else:
      continue
    if any(h in c.lower() for h in _TIME_NAME_HINTS):
      score += 20
    if best is None or score > best[0]:
      best = (score, c)
  return best[1] if best else None


def parse_time(series: pd.Series) -> pd.Series:
  if pd.api.types.is_datetime64_any_dtype(series):
    return series
  if pd.api.types.is_integer_dtype(series) and series.between(1000, 3000).all():
    return pd.to_datetime(series.astype(str), format="%Y", errors="coerce")
  return pd.to_datetime(series, errors="coerce", format="mixed")


def infer_frequency(times: pd.Series) -> str | None:
  t = times.dropna().drop_duplicates().sort_values()
  if len(t) < 3:
    return None
  try:
    freq = pd.infer_freq(t.tail(min(len(t), 500)))
  except (TypeError, ValueError):
    freq = None
  if freq:
    return freq
  diffs = t.diff().dropna()
  if diffs.empty:
    return None
  med = diffs.median()
  try:
    return pd.tseries.frequencies.to_offset(med).freqstr
  except ValueError:
    return None


def _make_sheet(name: str, df: pd.DataFrame) -> Sheet:
  df = _clean_frame(df)
  if df.empty:
    raise DataError(f"Sheet '{name}' has no data.")
  time_col = _detect_time_column(df)
  freq = infer_frequency(parse_time(df[time_col])) if time_col else None
  return Sheet(name=name, frame=df, time_column=time_col, frequency=freq)


def load_file(path: str | None = None, content: bytes | None = None, filename: str | None = None) -> Dataset:
  if content is None:
    if not path or not os.path.isfile(path):
      raise DataError(f"File not found: {path}")
    with open(path, "rb") as f:
      content = f.read()
  filename = filename or os.path.basename(path or "data.csv")
  ext = os.path.splitext(filename)[1].lower()
  if ext not in SUPPORTED_EXTENSIONS:
    raise DataError(f"Unsupported file type '{ext}'. Use CSV, TSV or Excel (.xlsx).")

  sheets: dict[str, Sheet] = {}
  if ext in (".xlsx", ".xlsm", ".xls"):
    try:
      book = pd.read_excel(io.BytesIO(content), sheet_name=None)
    except ImportError as e:
      raise DataError(f"Cannot read {ext} files: {e}. Save the file as .xlsx or .csv.") from e
    for sheet_name, df in book.items():
      try:
        sheets[str(sheet_name)] = _make_sheet(str(sheet_name), df)
      except DataError:
        continue
    if not sheets:
      raise DataError("The workbook has no sheets with data.")
  else:
    df = _read_text_table(content, ext)
    sheets["data"] = _make_sheet("data", df)

  return Dataset(id=uuid.uuid4().hex[:12], name=filename, path=path, sheets=sheets)


# --------------------------------------------------------------------------- description


def describe_sheet(sheet: Sheet, preview_rows: int = 50) -> dict[str, Any]:
  df = sheet.frame
  columns = []
  for c in df.columns:
    s = df[c]
    numeric = pd.api.types.is_numeric_dtype(s) and not pd.api.types.is_bool_dtype(s)
    info: dict[str, Any] = {
      "name": c,
      "dtype": str(s.dtype),
      "numeric": bool(numeric),
      "missing": int(s.isna().sum()),
      "unique": int(s.nunique(dropna=True)),
    }
    if numeric:
      v = s.astype(float)
      info.update(
        min=_f(v.min()), max=_f(v.max()), mean=_f(v.mean()), std=_f(v.std()),
        last_valid_row=int(v.last_valid_index()) if v.last_valid_index() is not None else None,
      )
    columns.append(info)

  # Candidate id columns for long-format data: low-cardinality non-numeric, non-time columns.
  id_candidates = [
    c["name"]
    for c in columns
    if not c["numeric"] and c["name"] != sheet.time_column and 1 < c["unique"] <= max(2, len(df) // 3)
  ]
  preview = df.head(preview_rows).copy()
  for c in preview.columns:
    if pd.api.types.is_datetime64_any_dtype(preview[c]):
      preview[c] = preview[c].dt.strftime("%Y-%m-%d %H:%M:%S")
  time_range = None
  if sheet.time_column:
    t = parse_time(df[sheet.time_column]).dropna()
    if not t.empty:
      time_range = [t.min().isoformat(), t.max().isoformat()]
  return {
    "name": sheet.name,
    "rows": int(len(df)),
    "columns": columns,
    "time_column": sheet.time_column,
    "frequency": sheet.frequency,
    "time_range": time_range,
    "id_candidates": id_candidates,
    "preview": {
      "columns": list(preview.columns),
      "rows": [[_cell(v) for v in row] for row in preview.itertuples(index=False)],
    },
  }


def _f(x: Any) -> float | None:
  try:
    x = float(x)
  except (TypeError, ValueError):
    return None
  return x if np.isfinite(x) else None


def _cell(v: Any) -> Any:
  if v is None:
    return None
  if isinstance(v, (float, np.floating)):
    return float(v) if np.isfinite(v) else None
  if isinstance(v, (np.integer,)):
    return int(v)
  if isinstance(v, pd.Timestamp):
    return v.isoformat()
  return v if isinstance(v, (int, str, bool)) else str(v)


# --------------------------------------------------------------------------- series extraction


@dataclasses.dataclass
class SeriesSpec:
  """What the user picked in the column mapper."""

  time_column: str | None = None
  id_column: str | None = None
  targets: list[str] = dataclasses.field(default_factory=list)
  past_covariates: list[str] = dataclasses.field(default_factory=list)
  future_covariates: list[str] = dataclasses.field(default_factory=list)
  fill_method: str = "interpolate"  # interpolate | ffill | zero
  start_row: int | None = None  # optional slice of the history (inclusive, after sorting)
  end_row: int | None = None  # exclusive


@dataclasses.dataclass
class SeriesGroup:
  """One forecasting unit: aligned targets + covariates for a single id."""

  key: str
  times: pd.Series | None  # timestamps for all rows (history + future-covariate rows)
  targets: np.ndarray  # (n_targets, n_hist)
  past_cov: np.ndarray | None  # (n_po, n_hist)
  future_cov: np.ndarray | None  # (n_pf, n_hist + n_future_rows)
  n_future_rows: int  # rows after the history that carry future covariate values
  frequency: str | None


def _fill(arr: np.ndarray, method: str) -> np.ndarray:
  s = pd.Series(arr, dtype=float)
  if s.isna().all():
    return np.zeros_like(arr, dtype=np.float32)
  if method == "zero":
    s = s.fillna(0.0)
  elif method == "ffill":
    s = s.ffill().bfill()
  else:
    s = s.interpolate(method="linear", limit_direction="both")
  return s.to_numpy(dtype=np.float32)


def extract_groups(sheet: Sheet, spec: SeriesSpec) -> list[SeriesGroup]:
  df = sheet.frame
  missing = [c for c in [*spec.targets, *spec.past_covariates, *spec.future_covariates] if c not in df.columns]
  if missing:
    raise DataError(f"Columns not found: {', '.join(missing)}")
  if not spec.targets:
    raise DataError("Pick at least one target column to forecast.")
  for c in [*spec.targets, *spec.past_covariates, *spec.future_covariates]:
    if not pd.api.types.is_numeric_dtype(df[c]):
      raise DataError(f"Column '{c}' is not numeric.")
  overlap = set(spec.targets) & (set(spec.past_covariates) | set(spec.future_covariates))
  if overlap:
    raise DataError(f"A column can't be both a target and a covariate: {', '.join(sorted(overlap))}")

  time_col = spec.time_column or None
  if time_col and time_col not in df.columns:
    raise DataError(f"Time column '{time_col}' not found.")

  if spec.id_column:
    if spec.id_column not in df.columns:
      raise DataError(f"ID column '{spec.id_column}' not found.")
    parts = [(str(k), g) for k, g in df.groupby(spec.id_column, sort=True)]
  else:
    parts = [("series", df)]

  groups = []
  for key, g in parts:
    g = g.copy()
    times = None
    if time_col:
      g["__t"] = parse_time(g[time_col])
      g = g[g["__t"].notna()].sort_values("__t", kind="stable")
      times = g["__t"].reset_index(drop=True)
    g = g.reset_index(drop=True)

    tgt = g[spec.targets].astype(float)
    last_valid = tgt.apply(lambda s: s.last_valid_index()).max()
    first_valid = tgt.apply(lambda s: s.first_valid_index()).min()
    if last_valid is None or pd.isna(last_valid):
      continue
    first_valid = int(first_valid)
    n_hist_end = int(last_valid) + 1

    start = first_valid
    end = n_hist_end
    if spec.start_row is not None:
      start = max(start, int(spec.start_row))
    if spec.end_row is not None:
      end = min(end, int(spec.end_row))
    if end - start < 2:
      raise DataError(f"Series '{key}' has fewer than 2 usable points.")

    targets = np.stack([_fill(tgt[c].to_numpy()[start:end], spec.fill_method) for c in spec.targets])
    past_cov = None
    if spec.past_covariates:
      pc = g[spec.past_covariates].astype(float)
      past_cov = np.stack([_fill(pc[c].to_numpy()[start:end], spec.fill_method) for c in spec.past_covariates])

    future_cov = None
    n_future = 0
    if spec.future_covariates:
      fc = g[spec.future_covariates].astype(float)
      # Future rows = rows after the history end whose covariates are all present.
      fut = fc.iloc[end:]
      complete = fut.notna().all(axis=1).to_numpy()
      n_future = int(np.argmin(complete)) if not complete.all() else len(complete)
      future_cov = np.stack(
        [_fill(fc[c].to_numpy()[start : end + n_future], spec.fill_method) for c in spec.future_covariates]
      )

    gtimes = times.iloc[start : end + max(n_future, 0)].reset_index(drop=True) if times is not None else None
    freq = infer_frequency(gtimes.iloc[: end - start]) if gtimes is not None else None
    groups.append(
      SeriesGroup(
        key=key,
        times=gtimes,
        targets=targets,
        past_cov=past_cov,
        future_cov=future_cov,
        n_future_rows=n_future,
        frequency=freq or sheet.frequency,
      )
    )
  if not groups:
    raise DataError("No series with data were found for the selected targets.")
  return groups


def future_timestamps(times: pd.Series | None, n_hist: int, horizon: int, freq: str | None) -> list[str] | None:
  """Timestamps for the forecast steps after position `n_hist`."""
  if times is None or n_hist == 0:
    return None
  known = list(times.iloc[n_hist : n_hist + horizon])
  last = times.iloc[n_hist - 1]
  if len(known) < horizon:
    if not freq:
      return None
    try:
      extra = pd.date_range(start=known[-1] if known else last, periods=horizon - len(known) + 1, freq=freq)[1:]
    except (ValueError, TypeError):
      return None
    known += list(extra)
  return [pd.Timestamp(t).isoformat() for t in known[:horizon]]


class DatasetStore:
  def __init__(self, max_items: int = 32) -> None:
    self._items: dict[str, Dataset] = {}
    self._order: list[str] = []
    self._lock = threading.Lock()
    self._max = max_items

  def add(self, ds: Dataset) -> Dataset:
    with self._lock:
      self._items[ds.id] = ds
      self._order.append(ds.id)
      while len(self._order) > self._max:
        self._items.pop(self._order.pop(0), None)
    return ds

  def get(self, dataset_id: str) -> Dataset:
    ds = self._items.get(dataset_id)
    if ds is None:
      raise DataError("Dataset not loaded (the engine may have restarted). Re-open the file.")
    return ds
