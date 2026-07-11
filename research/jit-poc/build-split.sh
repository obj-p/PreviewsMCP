#!/usr/bin/env bash
# W7 integrated auto-split POC — build + run + measure.
#
# Builds:
#   build/libStable.dylib + build/Stable.swiftmodule  — stable module,
#       -enable-testing, non-resilient (the bulk of a user target)
#   build/split_preview_v1.o / _v2.o — the editable unit: single-file
#       @testable compile against the prebuilt Stable.swiftmodule
#   build/host_split — LLJIT agent stand-in (see src/host_split.cpp)
#
# `./build-split.sh`      — build everything, run the v1/v2 pixel check.
# `./build-split.sh time` — additionally measure edit->pixels: recompile
#       v2 from source + spawn host (respawn semantics per W3/W4) and
#       report the wall-clock split.
#
# Toolchain conventions match build.sh (brewed LLVM clang++ for the
# host, xcrun swiftc for Swift, arm64 only).

set -euo pipefail

POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${POC_DIR}/build"
SRC_DIR="${POC_DIR}/src"
SWIFT_DIR="${POC_DIR}/swift"
mkdir -p "${BUILD_DIR}"

LLVM_PREFIX="$(brew --prefix llvm)"
LLVM_CLANG="${LLVM_PREFIX}/bin/clang++"
LLVM_CONFIG="${LLVM_PREFIX}/bin/llvm-config"
SWIFTC="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

echo "[split] swiftc: $("${SWIFTC}" --version | head -1)"

# -- stable module: dylib + swiftmodule, -enable-testing ---------------
echo "[split] swiftc Stable.swift -> build/libStable.dylib + Stable.swiftmodule"
"${SWIFTC}" \
    -parse-as-library \
    -enable-testing \
    -module-name Stable \
    -emit-library -o "${BUILD_DIR}/libStable.dylib" \
    -emit-module -emit-module-path "${BUILD_DIR}/Stable.swiftmodule" \
    -sdk "${SDK_PATH}" \
    "${SWIFT_DIR}/Stable.swift"

# -- editable unit: single-file @testable compiles ---------------------
compile_preview() { # $1=src $2=out
    "${SWIFTC}" \
        -parse-as-library \
        -emit-object \
        -module-name Preview \
        -I "${BUILD_DIR}" \
        -sdk "${SDK_PATH}" \
        -o "$2" \
        "$1"
}
echo "[split] swiftc split_preview_v1.swift -> build/split_preview_v1.o"
compile_preview "${SWIFT_DIR}/split_preview_v1.swift" "${BUILD_DIR}/split_preview_v1.o"
echo "[split] swiftc split_preview_v2.swift -> build/split_preview_v2.o"
compile_preview "${SWIFT_DIR}/split_preview_v2.swift" "${BUILD_DIR}/split_preview_v2.o"

# -- host ---------------------------------------------------------------
LLVM_COMPONENTS=(orcjit jitlink native nativecodegen runtimedyld
                 aarch64codegen aarch64asmparser aarch64desc)
LLVM_CXXFLAGS=$("${LLVM_CONFIG}" --cxxflags)
LLVM_LDFLAGS=$("${LLVM_CONFIG}" --ldflags)
LLVM_LIBS=$("${LLVM_CONFIG}" --libs "${LLVM_COMPONENTS[@]}")
LLVM_SYSLIBS=$("${LLVM_CONFIG}" --system-libs)
RTTI_FLAG="-fno-rtti"
[[ "$("${LLVM_CONFIG}" --has-rtti)" == "YES" ]] && RTTI_FLAG="-frtti"

echo "[split] clang++ src/ObjCSelrefPlugin.cpp + host_split.cpp -> build/host_split"
# shellcheck disable=SC2086
"${LLVM_CLANG}" \
    ${LLVM_CXXFLAGS} ${RTTI_FLAG} -fno-exceptions \
    -O2 -g -arch arm64 \
    -isysroot "${SDK_PATH}" \
    -o "${BUILD_DIR}/host_split" \
    "${SRC_DIR}/ObjCSelrefPlugin.cpp" "${SRC_DIR}/host_split.cpp" \
    ${LLVM_LDFLAGS} ${LLVM_LIBS} ${LLVM_SYSLIBS} \
    -lobjc \
    -Wl,-rpath,"${LLVM_PREFIX}/lib"

# Locate the ORC runtime archive (ExecutorNativePlatform needs it).
ORC_RT="${LLVM_PREFIX}/lib/clang/$("${LLVM_CONFIG}" --version | cut -d. -f1)/lib/darwin/liborc_rt_osx.a"
if [[ ! -f "${ORC_RT}" ]]; then
    ORC_RT=$(find "${LLVM_PREFIX}/lib/clang" -name "liborc_rt_osx.a" -type f 2>/dev/null | head -1)
fi
echo "[split] ORC runtime: ${ORC_RT}"

# -- run the pixel check ------------------------------------------------
echo "[split] running host_split (v1 + v2 pixel check)"
"${BUILD_DIR}/host_split" \
    "${ORC_RT}" \
    "${BUILD_DIR}/libStable.dylib" \
    "${BUILD_DIR}/split_preview_v1.o" \
    "${BUILD_DIR}/split_preview_v2.o"

# -- optional: generation soak (persistent-agent viability) -------------
if [[ "${1:-}" == "soak" ]]; then
    N="${2:-500}"
    echo "[split] soaking ${N} generations in one persistent host"
    "${BUILD_DIR}/host_split" \
        "${ORC_RT}" \
        "${BUILD_DIR}/libStable.dylib" \
        "${BUILD_DIR}/split_preview_v1.o" \
        "${BUILD_DIR}/split_preview_v2.o" \
        "${N}"
fi

# -- optional: edit->pixels wall-clock (respawn semantics) --------------
if [[ "${1:-}" == "time" ]]; then
    echo "[split] timing edit->pixels (compile v2 + spawn host + link + render)"
    for i in 1 2 3; do
        t0=$(python3 -c 'import time; print(time.time())')
        compile_preview "${SWIFT_DIR}/split_preview_v2.swift" "${BUILD_DIR}/split_preview_v2.o"
        t1=$(python3 -c 'import time; print(time.time())')
        "${BUILD_DIR}/host_split" \
            "${ORC_RT}" \
            "${BUILD_DIR}/libStable.dylib" \
            "${BUILD_DIR}/split_preview_v2.o" >/dev/null
        t2=$(python3 -c 'import time; print(time.time())')
        python3 -c "print(f'[split] rep $i: compile {(${t1}-${t0})*1000:.0f} ms + host(spawn+link+render) {(${t2}-${t1})*1000:.0f} ms = edit->pixels {(${t2}-${t0})*1000:.0f} ms')"
    done
fi
