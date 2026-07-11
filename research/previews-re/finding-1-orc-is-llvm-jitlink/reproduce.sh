#!/usr/bin/env bash
# Finding 1 — Apple's Xcode-Previews runtime JIT engine IS LLVM ORC + JITLink.
#
# Reproduction: boot a VM with Xcode installed, dump the VM-side exported
# symbols of XOJITExecutor.framework (only reachable in-guest — no host SDK
# .tbd stub), and assert every load-bearing ORC/JITLink symbol in
# expected.fingerprint is present. Green = the finding still holds on the
# guest's macOS/Xcode; red = drift.
#
# VM-DEPENDENT: requires a baked bundle whose ${SNAPSHOT} has Xcode installed
# (post-xcode / post-xcode-sip-amfi). SIP/AMFI are NOT needed for a symbol
# dump — this is the SSH-only, cleanest finding. Not runnable until the bake
# ladder has produced the snapshot.
#
# Usage:
#   VZY_BUNDLE=~/VMs/previews.bundle ./reproduce.sh [snapshot-name]
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FINGERPRINT="${HERE}/expected.fingerprint"
VZY="${VZY:-$HOME/Projects/vzy/.build/release/vzy}"
BUNDLE="${VZY_BUNDLE:?set VZY_BUNDLE to the baked vz bundle path}"
SNAPSHOT="${1:-post-xcode}"
FRAMEWORK="/System/Library/PrivateFrameworks/XOJITExecutor.framework/Versions/A/XOJITExecutor"

[[ -x "$VZY" ]] || { echo "FATAL: vzy not built at $VZY (build.sh in ~/Projects/vzy)" >&2; exit 1; }
[[ -d "$BUNDLE" ]] || { echo "FATAL: bundle not found: $BUNDLE (run the bake first)" >&2; exit 1; }

cleanup() { "$VZY" stop "$BUNDLE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== finding-1: XOJITExecutor is LLVM ORC + JITLink =="
echo "[vm] restore snapshot '${SNAPSHOT}' and boot"
"$VZY" snapshot restore "$BUNDLE" "$SNAPSHOT"
"$VZY" boot "$BUNDLE" --skip-ssh-wait &
"$VZY" ssh "$BUNDLE" true   # blocks until SSH is reachable

echo "[vm] dyld_info -exports ${FRAMEWORK}"
exports="$("$VZY" ssh "$BUNDLE" "xcrun dyld_info -exports '${FRAMEWORK}'" 2>/dev/null)"
if [[ -z "$exports" ]]; then
    echo "FAIL: no exports returned — framework path wrong or dump failed" >&2
    exit 1
fi

miss=0
while IFS= read -r sym; do
    [[ -z "$sym" || "$sym" == \#* ]] && continue
    if grep -qF -- "$sym" <<<"$exports"; then
        echo "  PASS  present: ${sym}"
    else
        echo "  FAIL  MISSING: ${sym}"
        miss=$((miss + 1))
    fi
done < "$FINGERPRINT"

if (( miss == 0 )); then
    echo "== finding-1 REPRODUCED: all fingerprint symbols present =="
    exit 0
fi
echo "== finding-1 BROKEN: ${miss} fingerprint symbol(s) missing (drift) ==" >&2
exit 1
