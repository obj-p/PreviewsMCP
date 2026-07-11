#!/usr/bin/env bash
# JIT-link POC — reproduction driver.
#
# Regenerates the W2 finding: Apple's Xcode-Previews runtime JIT engine is
# LLVM ORC + JITLink (see archive/previews-research-3201
# research/scripts/analysis/q6-jit-runtime-findings.md), and that SAME public
# architecture — LLVM ORC/JITLink + `swiftc -emit-object` — can ingest Swift
# objects and hot-swap function implementations for every hard Swift emission
# pattern. Each harness below JIT-links one pattern and asserts the expected
# override output; green == the public-layer architecture still reproduces the
# finding on the current toolchain (drift in LLVM / swiftc / macOS is caught
# here).
#
# VM-free: this is host-tier reproduction. No Virtualization.framework, no
# snapshot. Requires brewed LLVM (`brew install llvm`) + an Xcode toolchain.

set -uo pipefail

POC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${POC_DIR}/build"
LLVM_PREFIX="$(brew --prefix llvm)"
LLVM_CONFIG="${LLVM_PREFIX}/bin/llvm-config"
ORC_RT="$(find "${LLVM_PREFIX}/lib/clang" -name liborc_rt_osx.a -type f 2>/dev/null | head -1)"

fail=0
pass=0

# check <label> <expected-substring> -- <command...>
# Runs the command, asserts stdout+stderr contains the substring AND exit 0.
check() {
    local label="$1" want="$2"; shift 2
    [[ "$1" == "--" ]] && shift
    local out rc
    out="$("$@" 2>&1)"; rc=$?
    if [[ $rc -eq 0 && "$out" == *"$want"* ]]; then
        echo "  PASS  ${label}  (matched: \"${want}\")"
        pass=$((pass + 1))
    else
        echo "  FAIL  ${label}  (rc=${rc}, wanted: \"${want}\")"
        echo "${out}" | sed 's/^/        | /' | tail -12
        fail=$((fail + 1))
    fi
}

echo "== jit-poc reproduction =="
echo "[env] LLVM $("${LLVM_CONFIG}" --version) at ${LLVM_PREFIX}"
echo "[env] swiftc $(xcrun swiftc --version | head -1)"
echo "[env] macOS SDK $(xcrun --sdk macosx --show-sdk-version)"
if [[ -z "${ORC_RT}" || ! -f "${ORC_RT}" ]]; then
    echo "FATAL: liborc_rt_osx.a not found under ${LLVM_PREFIX}/lib/clang" >&2
    exit 1
fi

echo "== build =="
if ! "${POC_DIR}/build.sh" >/tmp/jitpoc_run_build.log 2>&1; then
    echo "FATAL: build.sh failed; see /tmp/jitpoc_run_build.log" >&2; exit 1
fi
if ! BUILD_ONLY=1 "${POC_DIR}/build-split.sh" >/tmp/jitpoc_run_split.log 2>&1; then
    echo "FATAL: build-split.sh failed; see /tmp/jitpoc_run_split.log" >&2; exit 1
fi
echo "  built"

echo "== assert findings =="
cd "${BUILD_DIR}" || { echo "FATAL: build dir missing: ${BUILD_DIR}" >&2; exit 1; }

# 1. Free-function override: v1 -> v2 in one process, two objects.
check "free-function override (v2)" "hello from swift v2" -- \
    ./host greet_v1.o greet_v2.o

# 2. Protocol-witness-table override + cross-JITDylib stretch.
check "protocol-witness override (v2)" "hello from v2" -- \
    ./host_witness Greeter.o greeter_v1.o greeter_v2.o conform_v1.o conform_v2.o
check "PWT cross-JITDylib stretch (v2)" "hello from v2 (stretch)" -- \
    ./host_witness Greeter.o greeter_v1.o greeter_v2.o conform_v1.o conform_v2.o

# 3. TLV + swift_once-guarded Swift global-init.
check "TLV + swift_once global-init" "sum_of_squares_1_to_100=338350" -- \
    ./host_tlv "${ORC_RT}" tlv_c_v1.o tlv_v1.o

# 4. ObjC selref uniquing plugin (Foundation-touching Swift).
check "ObjC selref uniquing plugin" "touchNSString: ns_v1=7 sum=42" -- \
    ./host_objc "${ORC_RT}" objc_v1.o

# 5. Swift async. v1 and the multi-await v2 are each loaded as the PRIMARY
#    object — both export @_cdecl("runAsync"), so loading both into one
#    JITDylib is an inherent duplicate-symbol collision, not a finding.
check "async function" "hello from async v1" -- \
    ./host_async "${ORC_RT}" async_v1.o
check "async multi-await (stretch)" "hello from async v2" -- \
    ./host_async "${ORC_RT}" async_v2.o

# 6. Auto-split: split -> @testable -> JIT-link -> pixels differ across edit.
check "auto-split pixel edit (W7)" "VERDICT: PASS" -- \
    ./host_split "${ORC_RT}" libStable.dylib split_preview_v1.o split_preview_v2.o

echo "== result: ${pass} passed, ${fail} failed =="
exit $(( fail > 0 ? 1 : 0 ))
