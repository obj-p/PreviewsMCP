#!/usr/bin/env bash
# Regenerate assets/demo.gif from scripts/demo.tape using vhs.
#
# One-time setup:
#   brew install vhs chafa
#
# Then:
#   scripts/record-demo.sh

set -euo pipefail

cd "$(dirname "$0")/.."

for tool in vhs chafa; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found on PATH (brew install $tool)" >&2
    exit 1
  fi
done

if [[ ! -x .build/release/previewsmcp ]]; then
  echo "Building previewsmcp (release)..."
  swift build -c release
fi

export PATH="$PWD/.build/release:$PATH"

mkdir -p assets
vhs scripts/demo.tape

echo "Wrote assets/demo.gif"
