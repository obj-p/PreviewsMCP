#!/usr/bin/env bash
#
# Compiles the iOS-simulator ORC executor glue (iossim-executor/server.cpp ->
# server.o) and copies it, the iossim LLVM TargetProcess libs, the iossim orc
# runtime, and the C bridging header into an output directory. The
# BundleIOSSimJIT build-tool plugin invokes this so the artifacts land in
# PreviewsIOS's resource bundle, where IOSHostBuilder finds them via
# Bundle.module to link the in-app JIT executor into the iOS host app.
#
# Usage: bundle-iossim-jit.sh <packageRoot> <outDir>
set -euo pipefail

ROOT="$1"
OUT="$2"

SRC_INC="$ROOT/third_party/llvm-project/llvm/include"
GEN_INC="$ROOT/third_party/llvm-build-iossim/include"
LIBDIR="$ROOT/third_party/llvm-build-iossim/lib"
RT="$ROOT/third_party/llvm-build-rt/lib/darwin/liborc_rt_iossim.a"
SERVER_CPP="$ROOT/iossim-executor/server.cpp"
SERVER_H="$ROOT/iossim-executor/server.h"

mkdir -p "$OUT"

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios16.0-simulator"
SERVER_O="$OUT/server.o"

if [ ! -e "$SERVER_O" ] || [ "$SERVER_CPP" -nt "$SERVER_O" ] || [ "$SERVER_H" -nt "$SERVER_O" ]; then
  xcrun clang++ \
    -target "$TARGET" -isysroot "$SDK" \
    -std=c++17 -fno-rtti -O2 \
    -I"$SRC_INC" -I"$GEN_INC" \
    -c "$SERVER_CPP" -o "$SERVER_O"
fi

cp "$RT" "$OUT/liborc_rt_iossim.a"
for lib in libLLVMOrcTargetProcess libLLVMOrcShared libLLVMSupport libLLVMTargetParser libLLVMDemangle; do
  cp "$LIBDIR/$lib.a" "$OUT/$lib.a"
done
