#!/usr/bin/env bash
# Runs every test of the project. The pre-push hook calls it, so a push with a failing test is refused.
#   scripts/check.sh            # app and engine
#   scripts/check.sh app        # Swift tests only
#   scripts/check.sh engine     # Python tests only
# The engine tests use the dev environment in .venv (see README, Development), or COGLF1_PYTHON.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WHAT="${1:-all}"
PY="${COGLF1_PYTHON:-$ROOT/.venv/bin/python}"

if [[ "$WHAT" != "all" && "$WHAT" != "app" && "$WHAT" != "engine" ]]; then
  echo "usage: scripts/check.sh [app|engine]" >&2
  exit 2
fi

VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' "$ROOT/engine/coglf1_engine/__init__.py")"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "__version__ in engine/coglf1_engine/__init__.py is '$VERSION', not a version like 0.1.8." >&2
  exit 1
fi

if [[ "$WHAT" == "all" || "$WHAT" == "app" ]]; then
  echo "==> App tests (swift test)"
  (cd "$ROOT/app" && swift test 2>&1 | grep -vE "^Test Case .* (started|passed)|^Test Suite .* started" )
fi

if [[ "$WHAT" == "all" || "$WHAT" == "engine" ]]; then
  echo "==> Engine tests (pytest)"
  if ! "$PY" -c "import pytest, timesfm3" 2>/dev/null; then
    echo "No test environment at $PY. Create it once with:" >&2
    echo "  python3.11 -m venv .venv && .venv/bin/pip install -r engine/requirements.txt -r engine/requirements-dev.txt" >&2
    exit 1
  fi
  "$PY" -m pytest "$ROOT/engine/tests" -q
fi

echo "==> All checks passed (version $VERSION)"
