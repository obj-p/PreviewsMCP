#!/usr/bin/env bash
# Regenerate assets/demo.gif and the paired variant PNGs from scripts/demo.tape
# using vhs.
#
# One-time setup:
#   brew install vhs
#
# Then:
#   scripts/record-demo.sh

set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v vhs >/dev/null 2>&1; then
  echo "error: vhs not found on PATH (brew install vhs)" >&2
  exit 1
fi

if [[ -x .build/release/previewsmcp ]]; then
  bin_dir="$PWD/.build/release"
elif [[ -x .build/debug/previewsmcp ]]; then
  bin_dir="$PWD/.build/debug"
else
  echo "Building previewsmcp (release)..."
  swift build -c release
  bin_dir="$PWD/.build/release"
fi

export PATH="$bin_dir:$PATH"

mkdir -p assets
vhs scripts/demo.tape

if [[ -f /tmp/pmcp-demo/light.png && -f /tmp/pmcp-demo/dark.png ]]; then
  cp /tmp/pmcp-demo/light.png assets/preview-light.png
  cp /tmp/pmcp-demo/dark.png  assets/preview-dark.png
  echo "Wrote assets/demo.gif, assets/preview-light.png, assets/preview-dark.png"
else
  echo "Wrote assets/demo.gif (variant PNGs not found at /tmp/pmcp-demo/)" >&2
fi
