#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

node "$ROOT_DIR/tests/layoutmodel.test.js"
"$ROOT_DIR/tests/qml.test.sh"

# The drag test seizes the pointer for about 20 seconds, so it is opt-in:
# tests/all.sh --drag, or run tests/drag.test.py directly.
if [[ ${1:-} == "--drag" ]]; then
  if [[ -x $ROOT_DIR/tests/tools/vptr/vptr ]]; then
    python3 "$ROOT_DIR/tests/drag.test.py"
  else
    echo "drag.test.py: tests/tools/vptr/vptr not built, skipping" >&2
  fi
else
  echo "tests/all.sh: skipping the drag test, pass --drag to run it" >&2
fi
if command -v omarchy >/dev/null; then
  omarchy plugin validate "$ROOT_DIR"
fi

echo "all tests passed"
