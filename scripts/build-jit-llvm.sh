#!/usr/bin/env bash
#
# Builds the LLVM that PreviewsJITLink links against, from swiftlang/llvm-project
# pinned to the tag matching the installed Swift toolchain. We build from the
# Swift fork (not vanilla brew LLVM) so the ORC/JITLink + orc runtime we link
# match the in-process Swift runtime that consumes the sections we register.
#
# Opt-in: only contributors working on the JIT need to run this. The clone is
# shallow + sparse (no clang/swift/lldb source), and both source and build are
# gitignored under third_party/.
#
# Usage: scripts/build-jit-llvm.sh
set -euo pipefail

LLVM_TAG="swift-6.2.3-RELEASE"
LLVM_SHA="9784760565e8cae0bc0b97bad69aaf498408dc3d"
LLVM_REPO="https://github.com/swiftlang/llvm-project.git"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/third_party/llvm-project"
BUILD="$ROOT/third_party/llvm-build"

command -v cmake >/dev/null || { echo "error: cmake not found (brew install cmake)"; exit 1; }
command -v ninja >/dev/null || { echo "error: ninja not found (brew install ninja)"; exit 1; }

# 1. Shallow + sparse + partial clone, pinned to the exact commit.
if [ ! -e "$SRC/.git" ]; then
  echo "==> cloning llvm-project @ $LLVM_TAG (shallow, sparse)"
  mkdir -p "$SRC"
  git -C "$SRC" init -q
  git -C "$SRC" remote add origin "$LLVM_REPO"
  git -C "$SRC" config extensions.partialClone origin
  git -C "$SRC" sparse-checkout set --cone llvm compiler-rt cmake third-party runtimes
  git -C "$SRC" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$LLVM_TAG"
  git -C "$SRC" checkout -q FETCH_HEAD
fi

GOT="$(git -C "$SRC" rev-parse HEAD)"
if [ "$GOT" != "$LLVM_SHA" ]; then
  echo "error: pinned SHA mismatch: got $GOT, expected $LLVM_SHA"
  exit 1
fi
echo "==> source pinned at $LLVM_SHA"

# 1b. Local patches on top of the pinned tag (idempotent).
for PATCH in "$ROOT"/scripts/patches/llvm-*.patch; do
  [ -e "$PATCH" ] || continue
  if git -C "$SRC" apply --reverse --check "$PATCH" 2>/dev/null; then
    echo "==> patch already applied: $(basename "$PATCH")"
  else
    echo "==> applying patch: $(basename "$PATCH")"
    git -C "$SRC" apply "$PATCH"
  fi
done

BUILD_RT="$ROOT/third_party/llvm-build-rt"
CLANG="$(xcrun -f clang)"
CLANGXX="$(xcrun -f clang++)"

# 2. Phase 1: libLLVM dylib with ORC/JITLink. No runtimes (that path wants a
#    freshly-built clang for clang-resource-headers). Asserts on for JITLink
#    diagnostics.
echo "==> [1/4] configuring llvm"
cmake -G Ninja -S "$SRC/llvm" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DLLVM_TARGETS_TO_BUILD="AArch64;X86" \
  -DLLVM_BUILD_LLVM_DYLIB=ON \
  -DLLVM_LINK_LLVM_DYLIB=ON \
  -DLLVM_ENABLE_PROJECTS="" \
  -DLLVM_ENABLE_RUNTIMES="" \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_EXAMPLES=OFF

echo "==> [2/4] building libLLVM + llvm-config"
ninja -C "$BUILD" LLVM llvm-config

# 3. Phase 2: compiler-rt's orc runtime, standalone, built with the system
#    clang against the LLVM we just built. COMPILER_RT_DEBUG on for ORC_RT_DEBUG.
echo "==> [3/4] configuring compiler-rt (orc runtime, standalone)"
cmake -G Ninja -S "$SRC/compiler-rt" -B "$BUILD_RT" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_C_COMPILER="$CLANG" \
  -DCMAKE_CXX_COMPILER="$CLANGXX" \
  -DCOMPILER_RT_STANDALONE_BUILD=ON \
  -DLLVM_CONFIG_PATH="$BUILD/bin/llvm-config" \
  -DLLVM_CMAKE_DIR="$SRC/llvm/cmake/modules" \
  -DCOMPILER_RT_BUILD_ORC=ON \
  -DCOMPILER_RT_BUILD_BUILTINS=OFF \
  -DCOMPILER_RT_BUILD_SANITIZERS=OFF \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_DEBUG=ON

echo "==> [4/4] building orc runtime"
ninja -C "$BUILD_RT" orc

echo "==> done"
echo "    libLLVM: $BUILD/lib"
find "$BUILD" "$BUILD_RT" -name "liborc_rt_osx.a" -print
