#!/usr/bin/env bash
#
# Builds a minimal iOS-simulator .app that hosts the ORC executor in-process
# (iossim-jit-host/App.swift calls previewsmcp_ios_executor_start). Proves a
# Swift-built app can link the iossim LLVM TargetProcess libs + the server glue
# and run the EPC server as a real UIApplication. Requires
# scripts/build-jit-llvm-iossim.sh first.
#
# Usage: scripts/build-iossim-jit-host.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INC="$ROOT/third_party/llvm-project/llvm/include"
GEN_INC="$ROOT/third_party/llvm-build-iossim/include"
LIBDIR="$ROOT/third_party/llvm-build-iossim/lib"
SRC="$ROOT/iossim-jit-host"
OUT="$ROOT/.build-iossim/PreviewsMCPJITHost.app"

[ -e "$LIBDIR/libLLVMOrcTargetProcess.a" ] || { echo "error: run scripts/build-jit-llvm-iossim.sh first"; exit 1; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANGXX="$(xcrun -f clang++)"
SWIFTC="$(xcrun -f swiftc)"
TARGET="arm64-apple-ios16.0-simulator"
BUILD="$ROOT/.build-iossim"
mkdir -p "$BUILD"

echo "==> compiling server glue (iossim)"
"$CLANGXX" \
  -target "$TARGET" -isysroot "$SDK" \
  -std=c++17 -fno-rtti -O2 \
  -I"$SRC_INC" -I"$GEN_INC" \
  -c "$ROOT/iossim-executor/server.cpp" -o "$BUILD/server.o"

echo "==> compiling + linking app binary"
"$SWIFTC" \
  -emit-executable \
  -parse-as-library \
  -target "$TARGET" \
  -sdk "$SDK" \
  -module-name PreviewsMCPJITHost \
  -import-objc-header "$SRC/bridging.h" \
  -Onone -gnone \
  "$SRC/App.swift" \
  "$BUILD/server.o" \
  -L"$LIBDIR" \
  -lLLVMOrcTargetProcess -lLLVMOrcShared -lLLVMSupport -lLLVMTargetParser \
  -lLLVMDemangle \
  -lc++ \
  -o "$BUILD/PreviewsMCPJITHost"

echo "==> packaging .app"
rm -rf "$OUT"
mkdir -p "$OUT"
cp "$BUILD/PreviewsMCPJITHost" "$OUT/PreviewsMCPJITHost"
cp "$SRC/Info.plist" "$OUT/Info.plist"
codesign -s - -f "$OUT"

echo "==> done: $OUT"
