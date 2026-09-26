"""Run the engine: python -m coglf1_engine --port 8765 --models-dir ~/Library/Application\ Support/COGL-F1/models"""

import argparse
import os

# Let PyTorch fall back to CPU for any op Metal doesn't implement (fine-tuning backward passes).
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")


def _watch_parent(pid: int) -> None:
  """Exit if the app that launched us dies, so the engine never lingers as an orphan."""
  import threading
  import time

  def loop() -> None:
    while True:
      time.sleep(2)
      try:
        os.kill(pid, 0)
      except ProcessLookupError:
        os._exit(0)
      except PermissionError:
        pass

  threading.Thread(target=loop, name="parent-watch", daemon=True).start()


def main() -> None:
  parser = argparse.ArgumentParser(prog="coglf1_engine")
  parser.add_argument("--host", default="127.0.0.1")
  parser.add_argument("--port", type=int, default=8765)
  parser.add_argument(
    "--models-dir",
    default=os.path.expanduser("~/Library/Application Support/COGL-F1/models"),
  )
  parser.add_argument("--parent-pid", type=int, default=0, help="exit when this process goes away")
  args = parser.parse_args()

  if args.parent_pid:
    _watch_parent(args.parent_pid)

  import uvicorn

  from .server import create_app

  app = create_app(os.path.expanduser(args.models_dir))
  print(f"COGL-F1 engine listening on http://{args.host}:{args.port}", flush=True)
  uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
  main()
