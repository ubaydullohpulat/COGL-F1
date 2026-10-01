# Forecast Studio

Forecast Studio is a desktop app for local time-series forecasting. Powered by Google's TimesFM-3, it gives zero-shot multivariate forecasts with covariates and P10–P90 uncertainty bands. Drop in a CSV or Excel file, pick targets and a horizon, and forecast offline. No training, no cloud, data stays local.

Think LM Studio, but for forecasting: download the model with one button, load it, and play with every flag.

## Features

- **One-click model download** from Hugging Face (`google/timesfm-3.0-pytorch`, 1.32 GB) with progress, speed/ETA, pause/resume and SHA-256 verification. Other TimesFM 3 checkpoints can be downloaded by repo id or imported from a folder.
- **Forecast playground**: open CSV/TSV/Excel (multi-sheet), auto-detected date column and frequency, wide or long (series-ID) tables, and per-column roles (target, past covariate, future covariate).
- **Multivariate + covariates**: forecast several targets jointly (TimesFM 3 variate attention) or independently; past-only and future-known covariates.
- **Every flag exposed**:
  - inference: horizon, context length (≤ 15,360), symmetric averaging, z-normalization, force non-negative, sort quantiles, covariate padding (none/edge);
  - model: stitching, linear detrending and its threshold, iterative CPM-RevIN, value clip, frozen running stats;
  - load: backend (MLX on the Apple GPU, PyTorch on Metal or CPU), graph compile, batch size, max context.
- **Backtesting** with rolling windows: MAE, RMSE, MAPE, sMAPE, MASE, weighted quantile loss, 80%/40% interval coverage, and skill vs. naive.
- **Interactive chart**: history, median, 20/40/60/80% quantile bands, actuals, and a hover tooltip. Copy it as an image; export forecasts with all 9 quantiles to Excel or CSV.
- **Fine-tuning in the UI**: LoRA, last-N-layers, head-only or full fine-tuning on your own series, on the Apple GPU.
  - Quantile loss, held-out validation, warmup + cosine LR, early stopping.
  - Live loss charts against the zero-shot baseline.
  - The result is saved as a new model; LoRA is merged into the weights.
- **Local HTTP API** (like LM Studio's server): `POST /v1/forecast` and friends on `127.0.0.1`, with the schema at `/docs`.

## Install & run

Requirements: Apple Silicon Mac, macOS 14+. Nothing else has to be installed: the app downloads its own Python. Building from source needs the Swift toolchain (Xcode or the command line tools).

```bash
scripts/build_app.sh            # → dist/Forecast Studio.app  (add --dmg for a disk image)
open "dist/Forecast Studio.app"
```

On first launch:
1. **Install runtime** downloads [uv](https://docs.astral.sh/uv/) and Python 3.12 if the Mac has none, then creates a private Python environment at `~/Library/Application Support/COGL-F1/runtime/venv` with `timesfm[mlx,torch]==3.0.2` (about 1 GB, one time).
2. **Models → Download model** fetches TimesFM 3 into `~/Library/Application Support/COGL-F1/models`.
3. Open a file (or a bundled sample) and press **Run** (⌘R).

## Data format

| Layout | Example |
|---|---|
| Wide | `date, sales, visits, temperature, promo`: one column per series |
| Long | `store, month, revenue`: choose `store` as **Series ID**; every store is forecast in one batch |

Future covariates (planned promotions, holidays, weather forecasts) go in rows after the last target value, one row per forecast step, with the target cells left empty. See `samples/retail_sales.csv`.

## Architecture

```
app/      SwiftUI macOS client (Swift Charts). Downloads models itself; runs the engine as a child process.
engine/   Python engine (FastAPI) on top of google-research/timesfm 3.0.2:
          data.py      CSV/Excel parsing, time/frequency detection, series extraction
          runtime.py   model library, MLX/PyTorch loading, flags, forecasting, backtest metrics, export
          finetune.py  LoRA / partial / full fine-tuning (PyTorch MPS), merged checkpoint export
          server.py    HTTP API used by the app and by your scripts
samples/  synthetic demo datasets (regenerate with samples/make_samples.py)
scripts/  build_app.sh (bundle + ad-hoc sign + optional DMG), make_icon.swift
```

## Development

```bash
python3.11 -m venv .venv && .venv/bin/pip install -r engine/requirements.txt -r engine/requirements-dev.txt
.venv/bin/python -m pytest engine/tests -q        # end-to-end engine tests on a tiny random-weight model
cd app && swift build                             # compile the app
COGLF1_PYTHON=$PWD/../.venv/bin/python .build/debug/COGLF1   # run against the dev venv
```

### Tests

```bash
scripts/check.sh                        # every test: the app (swift test) and the engine (pytest)
git config core.hooksPath .githooks     # once per clone: run them before every push
```

With the hook on, `git push` is refused while a test fails. The app's tests are in `app/Tests`, the engine's in `engine/tests`. A fixed bug gets a test that fails without the fix, so it cannot come back unnoticed. The app's tests also run on GitHub for every push (`.github/workflows/tests.yml`); the engine's need the Apple GPU and run only on the Mac.

## Updates

When the app opens it asks GitHub for the latest release of this repository. If that is newer, it offers to update: it downloads the DMG, checks it against the published SHA-256 and the developer's signature, replaces itself and restarts. "Don't show this again" ends the question; Settings → Updates turns it back on and has a manual check, as does the app menu.

To try an update without publishing one, point the app at a local feed: `COGLF1_UPDATE_FEED=file:///path/feed.json` with the JSON shape of GitHub's `releases/latest`.

## Release

Pushing a version tag builds, notarizes, and publishes the DMG. The tag must match `__version__` in `engine/coglf1_engine/__init__.py`. For `0.1.1` that file contains `__version__ = "0.1.1"` and the tag is `v0.1.1`.

Commit the version bump to `main`, then:

```bash
git push origin main
git tag v0.1.1
git push origin v0.1.1
```

The workflow is `.github/workflows/release.yml`. It runs only on that tag push. The DMG is attached to the GitHub Release when the Actions run succeeds.

## License

The app and engine code are Apache-2.0 (see `LICENSE`). TimesFM 3.0 **weights** are released by Google under the *TimesFM Non-Commercial License v1.0*: research and non-production use only. Fine-tuned models inherit that license.
