"""Regenerate the bundled sample datasets (synthetic, deterministic).

  .venv/bin/python samples/make_samples.py
"""

import os

import numpy as np
import pandas as pd

HERE = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)

# 1. Daily retail: two targets, a past-only covariate and future-known promos/holidays (28 future rows).
n_hist, n_fut = 730, 28
dates = pd.date_range("2024-01-01", periods=n_hist + n_fut, freq="D")
t = np.arange(n_hist + n_fut)
dow = dates.dayofweek.to_numpy()
promo = (rng.random(len(t)) < 0.08).astype(int)
holiday = np.isin(dates.strftime("%m-%d"), ["01-01", "05-01", "07-04", "11-28", "12-24", "12-25", "12-31"]).astype(int)
temperature = 15 + 10 * np.sin(2 * np.pi * (t - 100) / 365.25) + rng.normal(0, 2, len(t))
weekly = np.array([0.9, 0.85, 0.9, 1.0, 1.15, 1.35, 1.2])[dow]
base = (200 + 0.08 * t) * weekly * (1 + 0.15 * np.sin(2 * np.pi * (t - 330) / 365.25))
sales = base * (1 + 0.35 * promo) * (1 - 0.5 * holiday) + 1.5 * temperature + rng.normal(0, 8, len(t))
visits = sales * 3.1 + rng.normal(0, 30, len(t))
retail = pd.DataFrame(
  {
    "date": dates.strftime("%Y-%m-%d"),
    "sales": np.round(sales, 1),
    "visits": np.round(visits).astype(float),
    "temperature": np.round(temperature, 1),
    "promo": promo,
    "holiday": holiday,
  }
)
retail.loc[n_hist:, ["sales", "visits", "temperature"]] = np.nan
retail.to_csv(os.path.join(HERE, "retail_sales.csv"), index=False)

# 2. Hourly energy load with a weather forecast known 48h ahead.
n_hist, n_fut = 24 * 90, 48
ts = pd.date_range("2025-03-01", periods=n_hist + n_fut, freq="h")
t = np.arange(n_hist + n_fut)
hour = ts.hour.to_numpy()
temp = 12 + 6 * np.sin(2 * np.pi * (hour - 9) / 24) + 5 * np.sin(2 * np.pi * t / (24 * 60)) + rng.normal(0, 1, len(t))
daily = 1 + 0.25 * np.sin(2 * np.pi * (hour - 7) / 24) + 0.15 * np.sin(4 * np.pi * (hour - 5) / 24)
weekend = np.where(ts.dayofweek.to_numpy() >= 5, 0.82, 1.0)
load = 900 * daily * weekend + 9 * np.abs(temp - 18) + rng.normal(0, 15, len(t))
energy = pd.DataFrame({"timestamp": ts.strftime("%Y-%m-%d %H:%M"), "load_mw": np.round(load, 1), "temperature_forecast": np.round(temp, 1)})
energy.loc[n_hist:, "load_mw"] = np.nan
energy.to_csv(os.path.join(HERE, "energy_load.csv"), index=False)

# 3. Monthly revenue for five stores in long format (Excel), plus a description sheet.
rows = []
months = pd.date_range("2019-01-01", periods=84, freq="MS")
for k, store in enumerate(["Downtown", "Airport", "Mall", "Harbor", "Uptown"]):
  level = 40000 + 9000 * k
  growth = 0.004 + 0.002 * k
  season = 1 + (0.12 + 0.03 * k) * np.sin(2 * np.pi * (np.arange(84) - 2 - k) / 12) + 0.25 * (months.month.to_numpy() == 12)
  spend = np.round(2000 + 400 * rng.random(84) + 300 * (months.month.to_numpy() >= 11), 0)
  covid = np.where((months >= "2020-04-01") & (months <= "2020-09-01"), 0.55 if store == "Airport" else 0.8, 1.0)
  rev = level * (1 + growth) ** np.arange(84) * season * covid + 3 * spend + rng.normal(0, 1500, 84)
  for m, r, s in zip(months, rev, spend):
    rows.append({"store": store, "month": m.date(), "revenue": round(float(r), 2), "marketing_spend": s})
with pd.ExcelWriter(os.path.join(HERE, "store_revenue.xlsx")) as xw:
  pd.DataFrame(rows).to_excel(xw, sheet_name="revenue", index=False)
  pd.DataFrame(
    {"about": ["Synthetic monthly revenue for 5 stores (long format).", "Pick 'store' as Series ID and 'revenue' as Target."]}
  ).to_excel(xw, sheet_name="readme", index=False)
print("samples written to", HERE)
