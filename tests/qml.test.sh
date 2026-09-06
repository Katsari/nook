#!/bin/bash
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
OMARCHY_SOURCE=${OMARCHY_PATH:-/usr/share/omarchy}
QMLLINT_BIN=$(command -v qmllint 2>/dev/null || true)
[[ -n $QMLLINT_BIN ]] || QMLLINT_BIN=/usr/lib/qt6/bin/qmllint
TMP=$(mktemp -d)
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The QML and the library must agree on the function set.
while read -r fn; do
  grep -q "^function $fn(" "$ROOT_DIR/LayoutModel.js" \
    || fail "BarWidget.qml calls Layout.$fn but LayoutModel.js does not define it"
done < <(grep -o 'Layout\.[A-Za-z_]*(' "$ROOT_DIR/BarWidget.qml" | sed 's/Layout\.\(.*\)(/\1/' | sort -u)

jq -e '.entryPoints.barWidget == "BarWidget.qml"' "$ROOT_DIR/manifest.json" >/dev/null \
  || fail "manifest.json barWidget entry point is not BarWidget.qml"

[[ -f $ROOT_DIR/LayoutModel.js ]] || fail "LayoutModel.js is missing"

grep -q 'target: "io.github.katsari.nook"' "$ROOT_DIR/BarWidget.qml" \
  || fail "IpcHandler target does not match the plugin id"

# qmllint: the mock-typed `bar` and host imports produce warnings on every
# plugin, so only hard errors fail the run.
if [[ -x $QMLLINT_BIN && -d $OMARCHY_SOURCE/shell/Commons ]]; then
  mkdir -p -- "$TMP/lint/qs"
  cp -- "$ROOT_DIR/BarWidget.qml" "$ROOT_DIR/LayoutModel.js" "$TMP/lint/"
  ln -s -- "$OMARCHY_SOURCE/shell/Commons" "$TMP/lint/qs/Commons"
  ln -s -- "$OMARCHY_SOURCE/shell/Ui" "$TMP/lint/qs/Ui"
  "$QMLLINT_BIN" --signal-handler-parameters disable -I "$TMP/lint" \
    "$TMP/lint/BarWidget.qml" >"$TMP/qmllint.log" 2>&1 || {
      sed -n '1,120p' "$TMP/qmllint.log" >&2
      fail "qmllint reported errors"
    }
  ! grep -q '^Error:' "$TMP/qmllint.log" || {
    grep '^Error:' "$TMP/qmllint.log" >&2
    fail "qmllint reported errors"
  }
fi

# Harness: the real BarWidget.qml against a mock bar and shell. PanelWindow
# needs a Wayland backend, so this leg needs a running session; the window it
# creates starts invisible and never maps.
if [[ -z ${WAYLAND_DISPLAY:-} || ! -d $OMARCHY_SOURCE/shell/Commons ]] || ! command -v quickshell >/dev/null; then
  echo "qml.test.sh: no omarchy session, skipping the runtime harness" >&2
  exit 0
fi

mkdir -p -- "$TMP/config"
cp -- "$ROOT_DIR/tests/fixtures/harness.qml" "$TMP/config/shell.qml"
ln -s -- "$OMARCHY_SOURCE/shell/Commons" "$TMP/config/Commons"
ln -s -- "$OMARCHY_SOURCE/shell/Ui" "$TMP/config/Ui"

env NOOK_SOURCE_DIR="$ROOT_DIR" \
  timeout 25 quickshell -p "$TMP/config" --no-color >"$TMP/quickshell.log" 2>&1 || true

if ! grep -Fq 'NOOK_TEST_OK' "$TMP/quickshell.log" \
    || grep -Fq 'NOOK_TEST_FAIL' "$TMP/quickshell.log"; then
  sed -n '1,120p' "$TMP/quickshell.log" >&2
  fail "harness did not pass"
fi

echo "qml.test.sh: lint, source checks, and harness passed"
