#!/usr/bin/env bash
set -euo pipefail

: "${VZ_BIN:?}"
: "${BUNDLE:?}"
: "${STATE:?}"
: "${REPO_ROOT:?}"
ADMIN_PASS="${ADMIN_PASS:-vz}"
XCODE_APP="${XCODE_APP:-/Applications/Xcode.app}"
JIT_CACHE="${JIT_CACHE:-/Users/admin/jit-cache}"

log() { printf '==> %s\n' "$*"; }
remote() { "$VZ_BIN" ssh "$BUNDLE" -- "$1"; }
rsudo() { printf '%s\n' "$ADMIN_PASS" | "$VZ_BIN" ssh "$BUNDLE" -- "sudo -S -p '' $1"; }
brewsh() { remote "eval \"\$(/opt/homebrew/bin/brew shellenv)\" && $1"; }

wait_ssh() {
    for _ in $(seq 1 60); do
        "$VZ_BIN" ssh "$BUNDLE" -- true 2>/dev/null && return 0
        sleep 5
    done
    return 1
}

BOOT_PID=""
cleanup() {
    "$VZ_BIN" stop "$BUNDLE" >/dev/null 2>&1 || true
    [ -n "$BOOT_PID" ] && wait "$BOOT_PID" 2>/dev/null || true
}
trap cleanup EXIT

log "booting guest"
"$VZ_BIN" boot "$BUNDLE" >"$STATE/jit-boot.log" 2>&1 &
BOOT_PID=$!
wait_ssh || { echo "guest did not become SSH-reachable" >&2; exit 1; }

if remote "test -f $JIT_CACHE/llvm-build-rt/lib/darwin/liborc_rt_osx.a && test -f $JIT_CACHE/llvm-build-iossim/lib/libLLVMOrcTargetProcess.a"; then
    log "JIT artifacts already present in $JIT_CACHE, skipping build"
else
    log "selecting Xcode at $XCODE_APP"
    rsudo "xcode-select -s $XCODE_APP"

    log "installing cmake + ninja"
    brewsh "brew install cmake ninja"

    log "streaming repo scripts into guest (~/jit-build-repo)"
    remote "rm -rf ~/jit-build-repo && mkdir -p ~/jit-build-repo"
    ( cd "$REPO_ROOT" && git archive --format=tar HEAD scripts ) | "$VZ_BIN" ssh "$BUNDLE" -- "tar -x -C ~/jit-build-repo"

    log "building macOS LLVM (build-jit-llvm.sh) — this is the long step"
    brewsh "cd ~/jit-build-repo && bash scripts/build-jit-llvm.sh"

    log "building iossim LLVM (build-jit-llvm-iossim.sh)"
    brewsh "cd ~/jit-build-repo && bash scripts/build-jit-llvm-iossim.sh"

    log "staging artifacts into $JIT_CACHE"
    remote "rm -rf $JIT_CACHE && mv ~/jit-build-repo/third_party $JIT_CACHE && rm -rf ~/jit-build-repo"
fi

log "verifying baked artifacts"
remote "test -d $JIT_CACHE/llvm-build && test -f $JIT_CACHE/llvm-build-rt/lib/darwin/liborc_rt_osx.a && test -f $JIT_CACHE/llvm-build-rt/lib/darwin/liborc_rt_iossim.a && test -f $JIT_CACHE/llvm-build-iossim/lib/libLLVMOrcTargetProcess.a && test -d $JIT_CACHE/llvm-project/llvm/include && echo present"

log "jit bake complete"
