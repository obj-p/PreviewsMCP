#!/usr/bin/env bash
# Build mq and codesign with the Virtualization entitlements (reused from vz).
# SPM doesn't codesign, so a raw `swift build` binary can't boot a VM.
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

ENTITLEMENTS="$SCRIPT_DIR/../../vz/Resources/vz.entitlements"
[ -f "$ENTITLEMENTS" ] || { echo "missing entitlements at $ENTITLEMENTS" >&2; exit 1; }

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/mq"
[ -x "$BIN" ] || { echo "no binary at $BIN" >&2; exit 1; }

echo "==> codesign $BIN"
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN"
echo "Built: $BIN"
