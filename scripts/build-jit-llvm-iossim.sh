#!/usr/bin/env bash
#
# Cross-builds the LLVM ORC TargetProcess executor libraries for the iOS
# simulator, so the in-app JIT host (the iOS analog of PreviewAgent) can run a
# SimpleRemoteEPCServer in-process. Only the executor-side libs are needed
# (OrcTargetProcess + OrcShared + Support + TargetParser); the heavy ORC
# controller stays on the macOS daemon and links the existing host libLLVM.
#
# Reuses the host llvm-tblgen from the macOS build (third_party/llvm-build), so
# scripts/build-jit-llvm.sh must have been run first. Uses a dedicated build dir
# (third_party/llvm-build-iossim) that the macOS build never touches, so the
# CMakeCache path-baking gotcha does not apply.
#
# Usage: scripts/build-jit-llvm-iossim.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/third_party/llvm-project"
HOST_BUILD="$ROOT/third_party/llvm-build"
BUILD="$ROOT/third_party/llvm-build-iossim"

command -v cmake >/dev/null || { echo "error: cmake not found"; exit 1; }
command -v ninja >/dev/null || { echo "error: ninja not found"; exit 1; }
[ -e "$SRC/.git" ] || { echo "error: run scripts/build-jit-llvm.sh first (no llvm source)"; exit 1; }
[ -x "$HOST_BUILD/bin/llvm-tblgen" ] || { echo "error: run scripts/build-jit-llvm.sh first (no host llvm-tblgen)"; exit 1; }

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
echo "==> iphonesimulator sdk: $SDK"

echo "==> [1/2] configuring llvm (iossim cross, executor libs only)"
cmake -G Ninja -S "$SRC/llvm" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_CROSSCOMPILING=TRUE \
  -DCMAKE_MACOSX_BUNDLE=OFF \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \
  -DLLVM_TABLEGEN="$HOST_BUILD/bin/llvm-tblgen" \
  -DLLVM_NATIVE_TOOL_DIR="$HOST_BUILD/bin" \
  -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_LINK_LLVM_DYLIB=OFF \
  -DLLVM_ENABLE_PROJECTS="" \
  -DLLVM_ENABLE_RUNTIMES="" \
  -DLLVM_BUILD_TOOLS=OFF \
  -DLLVM_BUILD_UTILS=OFF \
  -DLLVM_BUILD_RUNTIME=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_INCLUDE_TOOLS=OFF

echo "==> [2/2] building LLVMOrcTargetProcess (+ deps)"
ninja -C "$BUILD" LLVMOrcTargetProcess

echo "==> done"
find "$BUILD/lib" -name "libLLVMOrcTargetProcess.a" -o -name "libLLVMOrcShared.a" \
  -o -name "libLLVMSupport.a" -o -name "libLLVMTargetParser.a" | sort
