#!/usr/bin/env bash
# W2 JITLink POC — build script.
#
# Phase 1 outputs (free-function override):
#   build/greet_v1.o     — Swift v1 free-function object
#   build/greet_v2.o     — Swift v2 free-function object
#   build/host           — Phase-1 C++ host harness
#
# Phase 2 step 1 outputs (protocol witness override):
#   build/Greeter.o          — shared protocol descriptor
#   build/Greeter.swiftmodule — module interface for v1/v2 import
#   build/greeter_v1.o   — v1 conformance + makeGreeting cdecl
#   build/greeter_v2.o   — v2 conformance + makeGreeting cdecl
#   build/host_witness   — Phase-2 step-1 C++ host harness
#
# Phase 2 step 2 outputs (TLVs + Swift global-init):
#   build/tlv_c_v1.o     — C _Thread_local probe (real Mach-O TLV)
#   build/tlv_v1.o       — Swift module-level `let` (swift_once init)
#   build/host_tlv       — Phase-2 step-2 C++ host harness
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

# -- Phase 2 step 1: Greeter module + v1/v2 witness objects -----------
#
# Build the shared Greeter protocol module first. We emit both the
# object and the .swiftmodule interface so v1/v2 can `import Greeter`.
# Using a separate -module-name keeps the protocol descriptor symbol
# stable and shared (not duplicated across v1/v2).
GREETER_FLAGS=(
    -parse-as-library
    -O
    -sdk "${SDK_PATH}"
    -module-name Greeter
    -wmo
)

echo "[build] swiftc Greeter.swift -> build/Greeter.{o,swiftmodule}"
"${SWIFTC}" "${GREETER_FLAGS[@]}" \
    -emit-object \
    -emit-module \
    -emit-module-path "${BUILD_DIR}/Greeter.swiftmodule" \
    -o "${BUILD_DIR}/Greeter.o" \
    "${SWIFT_DIR}/Greeter.swift"

# v1 and v2 each import Greeter. The -I flag adds the build dir to the
# module search path so swiftc finds Greeter.swiftmodule.
WITNESS_FLAGS=(
    -emit-object
    -parse-as-library
    -O
    -sdk "${SDK_PATH}"
    -I "${BUILD_DIR}"
    -wmo
)

echo "[build] swiftc greeter_v1.swift -> build/greeter_v1.o"
"${SWIFTC}" "${WITNESS_FLAGS[@]}" \
    -module-name greeter_v1 \
    -o "${BUILD_DIR}/greeter_v1.o" \
    "${SWIFT_DIR}/greeter_v1.swift"

echo "[build] swiftc greeter_v2.swift -> build/greeter_v2.o"
"${SWIFTC}" "${WITNESS_FLAGS[@]}" \
    -module-name greeter_v2 \
    -o "${BUILD_DIR}/greeter_v2.o" \
    "${SWIFT_DIR}/greeter_v2.swift"

# Stretch-goal pair: both compiled under the SAME module name
# `conform`, so their emitted symbols collide by name (only the
# witness bodies differ). Used to test cross-JITDylib conformance
# patching — see host_witness.cpp runStretchGoal().
echo "[build] swiftc conform_v1.swift -> build/conform_v1.o"
"${SWIFTC}" "${WITNESS_FLAGS[@]}" \
    -module-name conform \
    -o "${BUILD_DIR}/conform_v1.o" \
    "${SWIFT_DIR}/conform_v1.swift"

echo "[build] swiftc conform_v2.swift -> build/conform_v2.o"
"${SWIFTC}" "${WITNESS_FLAGS[@]}" \
    -module-name conform \
    -o "${BUILD_DIR}/conform_v2.o" \
    "${SWIFT_DIR}/conform_v2.swift"

# -- Phase 2 step 2: TLV + Swift global-init objects ------------------
#
# tlv_v1.swift: module-level `let` with a non-trivial initializer. The
# spike-relevant fact recorded in host_tlv.cpp's header: this does NOT
# lower to a Mach-O TLV; swiftc 6.x emits a regular global + a
# swift_once-protected init function + an addressor (vau) symbol. We
# build it anyway, both to verify that lifecycle JIT-links cleanly and
# to keep the spike's coverage of Swift global-init explicit.
echo "[build] swiftc tlv_v1.swift -> build/tlv_v1.o"
"${SWIFTC}" "${SWIFT_FLAGS[@]}" \
    -o "${BUILD_DIR}/tlv_v1.o" \
    "${SWIFT_DIR}/tlv_v1.swift"

# tlv_c_v1.c: real Mach-O TLV. Use brewed LLVM's clang so the C
# emission matches what we'd see in actual mixed-language code paths.
# arm64-only.
echo "[build] clang tlv_c_v1.c -> build/tlv_c_v1.o"
"${LLVM_PREFIX}/bin/clang" \
    -arch arm64 -O2 -isysroot "${SDK_PATH}" \
    -c -o "${BUILD_DIR}/tlv_c_v1.o" \
    "${SWIFT_DIR}/tlv_c_v1.c"

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

echo "[build] clang++ src/host_witness.cpp -> build/host_witness"
# shellcheck disable=SC2086
"${LLVM_CLANG}" \
    ${LLVM_CXXFLAGS} ${RTTI_FLAG} ${EXC_FLAG} \
    -O2 -g -arch arm64 \
    -o "${BUILD_DIR}/host_witness" \
    "${SRC_DIR}/host_witness.cpp" \
    ${LLVM_LDFLAGS} ${LLVM_LIBS} ${LLVM_SYSLIBS} \
    -Wl,-rpath,"${LLVM_PREFIX}/lib"

echo "[build] clang++ src/host_tlv.cpp -> build/host_tlv"
# shellcheck disable=SC2086
"${LLVM_CLANG}" \
    ${LLVM_CXXFLAGS} ${RTTI_FLAG} ${EXC_FLAG} \
    -O2 -g -arch arm64 \
    -o "${BUILD_DIR}/host_tlv" \
    "${SRC_DIR}/host_tlv.cpp" \
    ${LLVM_LDFLAGS} ${LLVM_LIBS} ${LLVM_SYSLIBS} \
    -Wl,-rpath,"${LLVM_PREFIX}/lib"

# Locate the ORC runtime archive (arm64 slice within a universal
# archive). We record the path so callers can hand it to host_tlv as
# argv[1]. brew's compiler-rt installs the universal `liborc_rt_osx.a`
# under lib/clang/<v>/lib/darwin/. host_tlv passes the path to LLVM's
# ExecutorNativePlatform, which extracts the matching slice itself.
ORC_RT="${LLVM_PREFIX}/lib/clang/$("${LLVM_CONFIG}" --version | cut -d. -f1)/lib/darwin/liborc_rt_osx.a"
if [[ ! -f "${ORC_RT}" ]]; then
    # Glob fallback in case the version dir doesn't match major-only.
    ORC_RT_CAND=$(find "${LLVM_PREFIX}/lib/clang" \
        -name "liborc_rt_osx.a" -type f 2>/dev/null | head -1)
    if [[ -n "${ORC_RT_CAND}" ]]; then
        ORC_RT="${ORC_RT_CAND}"
    fi
fi
if [[ -f "${ORC_RT}" ]]; then
    echo "[build] ORC runtime: ${ORC_RT}"
else
    echo "[build] WARNING: ORC runtime archive not found under ${LLVM_PREFIX}/lib/clang"
fi

echo "[build] OK"
echo "[build] artifacts:"
ls -la "${BUILD_DIR}/host" "${BUILD_DIR}/host_witness" "${BUILD_DIR}/host_tlv" \
       "${BUILD_DIR}/greet_v1.o" "${BUILD_DIR}/greet_v2.o" \
       "${BUILD_DIR}/Greeter.o" \
       "${BUILD_DIR}/greeter_v1.o" "${BUILD_DIR}/greeter_v2.o" \
       "${BUILD_DIR}/tlv_v1.o" "${BUILD_DIR}/tlv_c_v1.o"
