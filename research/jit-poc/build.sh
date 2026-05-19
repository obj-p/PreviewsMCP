#!/usr/bin/env bash
# Phase-1 W2 JITLink POC — build script.
#
# Produces:
#   build/greet_v1.o   — Swift v1 object via swiftc -emit-object
#   build/greet_v2.o   — Swift v2 object via swiftc -emit-object
#   build/host         — C++ host harness linked against brewed LLVM 22
#
# Conventions:
#   * brewed LLVM's clang++ — NOT xcrun's. xcrun's clang ships with
#     the Swift toolchain and isn't ABI-compatible with brewed LLVM's
#     headers and libs.
#   * swiftc from `xcode-select -p` — whatever Xcode toolchain is
#     currently selected.
#   * arm64 (Apple Silicon hosts only).

set -euo pipefail

# Resolve repo-relative paths regardless of where build.sh is invoked.
POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${POC_DIR}/build"
SRC_DIR="${POC_DIR}/src"
SWIFT_DIR="${POC_DIR}/swift"

mkdir -p "${BUILD_DIR}"

# -- toolchain probes -------------------------------------------------

LLVM_PREFIX="$(brew --prefix llvm)"
LLVM_CLANG="${LLVM_PREFIX}/bin/clang++"
LLVM_CONFIG="${LLVM_PREFIX}/bin/llvm-config"

if [[ ! -x "${LLVM_CLANG}" ]]; then
    echo "FATAL: brewed clang++ not found at ${LLVM_CLANG}" >&2
    exit 1
fi
if [[ ! -x "${LLVM_CONFIG}" ]]; then
    echo "FATAL: brewed llvm-config not found at ${LLVM_CONFIG}" >&2
    exit 1
fi

SWIFTC="$(xcrun --find swiftc)"
if [[ ! -x "${SWIFTC}" ]]; then
    echo "FATAL: swiftc not found via xcrun" >&2
    exit 1
fi

# Resolve the active macOS SDK. swiftc needs `-sdk <path>` (or
# `-target` plus matching SDK on path); without it the driver can't
# load the standard library for the current OS triple on macOS 26.
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
if [[ -z "${SDK_PATH}" || ! -d "${SDK_PATH}" ]]; then
    echo "FATAL: could not resolve macOS SDK path" >&2
    exit 1
fi

LLVM_VERSION="$("${LLVM_CONFIG}" --version)"
SWIFTC_VERSION="$("${SWIFTC}" --version | head -1)"

echo "[build] LLVM:   ${LLVM_VERSION} at ${LLVM_PREFIX}"
echo "[build] swiftc: ${SWIFTC_VERSION}"
echo "[build] swiftc path: ${SWIFTC}"
echo "[build] macOS SDK: ${SDK_VER} at ${SDK_PATH}"

# -- swift -> .o -------------------------------------------------------

# `-emit-object` produces a Mach-O relocatable object. We pass
# -parse-as-library to skip the implicit top-level-code wrapper. We
# also pass -module-name explicitly so the symbol mangling is stable
# across the two versions (otherwise swiftc derives the module name
# from the input file, and v1 vs v2 would mangle differently — fine
# for `@_cdecl` `_greet` but cleaner this way for any non-cdecl
# helpers).
SWIFT_FLAGS=(
    -emit-object
    -parse-as-library
    -O
    -sdk "${SDK_PATH}"
    -module-name poc
    -wmo
)

echo "[build] swiftc greet_v1.swift -> build/greet_v1.o"
"${SWIFTC}" "${SWIFT_FLAGS[@]}" \
    -o "${BUILD_DIR}/greet_v1.o" \
    "${SWIFT_DIR}/greet_v1.swift"

echo "[build] swiftc greet_v2.swift -> build/greet_v2.o"
"${SWIFTC}" "${SWIFT_FLAGS[@]}" \
    -o "${BUILD_DIR}/greet_v2.o" \
    "${SWIFT_DIR}/greet_v2.swift"

# -- C++ host harness --------------------------------------------------

LLVM_COMPONENTS=(
    orcjit
    jitlink
    native
    nativecodegen
    runtimedyld
    aarch64codegen
    aarch64asmparser
    aarch64desc
    aarch64info
    aarch64utils
    orcshared
)

LLVM_CXXFLAGS=$("${LLVM_CONFIG}" --cxxflags)
LLVM_LDFLAGS=$("${LLVM_CONFIG}" --ldflags)
LLVM_LIBS=$("${LLVM_CONFIG}" --libs "${LLVM_COMPONENTS[@]}")
LLVM_SYSLIBS=$("${LLVM_CONFIG}" --system-libs)

# -frtti / -fno-rtti must match LLVM's build. brewed LLVM 22 builds
# with RTTI ENABLED (you can verify via `llvm-config --has-rtti`).
# clang's default is -fno-rtti only when llvm-config says rtti=NO.
HAS_RTTI=$("${LLVM_CONFIG}" --has-rtti)
RTTI_FLAG=""
if [[ "${HAS_RTTI}" == "YES" ]]; then
    RTTI_FLAG="-frtti"
else
    RTTI_FLAG="-fno-rtti"
fi
echo "[build] LLVM has rtti: ${HAS_RTTI} (using ${RTTI_FLAG})"

# Exceptions: LLVM is built with -fno-exceptions; we follow suit.
EXC_FLAG="-fno-exceptions"

echo "[build] clang++ src/host.cpp -> build/host"
# shellcheck disable=SC2086
"${LLVM_CLANG}" \
    ${LLVM_CXXFLAGS} ${RTTI_FLAG} ${EXC_FLAG} \
    -O2 -g -arch arm64 \
    -o "${BUILD_DIR}/host" \
    "${SRC_DIR}/host.cpp" \
    ${LLVM_LDFLAGS} ${LLVM_LIBS} ${LLVM_SYSLIBS} \
    -Wl,-rpath,"${LLVM_PREFIX}/lib"

echo "[build] OK"
echo "[build] artifacts:"
ls -la "${BUILD_DIR}/host" "${BUILD_DIR}/greet_v1.o" "${BUILD_DIR}/greet_v2.o"
