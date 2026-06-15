#!/usr/bin/env bash
#
# Builds the minimal iOS-simulator ORC executor (iossim-executor/main.cpp),
# linking the iossim LLVM TargetProcess static libs + the iossim orc runtime.
# Requires scripts/build-jit-llvm-iossim.sh to have run first.
#
# Usage: scripts/build-iossim-executor.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INC="$ROOT/third_party/llvm-project/llvm/include"
GEN_INC="$ROOT/third_party/llvm-build-iossim/include"
LIBDIR="$ROOT/third_party/llvm-build-iossim/lib"
OUT="$ROOT/.build-iossim/iossim-executor"

[ -e "$LIBDIR/libLLVMOrcTargetProcess.a" ] || { echo "error: run scripts/build-jit-llvm-iossim.sh first"; exit 1; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANGXX="$(xcrun -f clang++)"
mkdir -p "$(dirname "$OUT")"

echo "==> compiling + linking iossim-executor"
"$CLANGXX" \
  -target arm64-apple-ios14.0-simulator \
  -isysroot "$SDK" \
  -std=c++17 -fno-rtti -O2 \
  -I"$SRC_INC" -I"$GEN_INC" \
  "$ROOT/iossim-executor/server.cpp" \
  "$ROOT/iossim-executor/main.cpp" \
  -L"$LIBDIR" \
  -lLLVMOrcTargetProcess -lLLVMOrcShared -lLLVMSupport -lLLVMTargetParser \
  -lLLVMDemangle \
  -framework CoreFoundation \
  -o "$OUT"

echo "==> ad-hoc codesigning"
codesign -s - -f "$OUT"

echo "==> done: $OUT"
file "$OUT"
