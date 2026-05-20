#!/usr/bin/env bash
# Build previewsvm and codesign with the entitlements required to use
# Virtualization.framework. SPM doesn't run codesign for us, so the raw
# `swift build` output won't have com.apple.security.virtualization on it
# and VZVirtualMachine init will fail at runtime.
#
# Usage: research/vm/build.sh [debug|release]
#   debug   — default; faster iteration
#   release — optimized; what we'd use for measurements
set -euo pipefail

CONFIGURATION="${1:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

ENTITLEMENTS="$SCRIPT_DIR/Resources/previewsvm.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "missing entitlements at $ENTITLEMENTS" >&2
    exit 1
fi

echo "==> swift build -c $CONFIGURATION"
swift build -c "$CONFIGURATION"

BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)/previewsvm"
if [[ ! -x "$BIN" ]]; then
    echo "build did not produce expected binary at $BIN" >&2
    exit 1
fi

echo "==> codesign --entitlements $ENTITLEMENTS $BIN"
# Ad-hoc signing (-s -) is enough on a research host for
# com.apple.security.virtualization. A Developer ID identity is only
# needed for distribution.
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BIN"

echo
echo "Built: $BIN"
echo "Entitlements:"
codesign -d --entitlements - "$BIN" 2>&1 | sed 's/^/    /'
