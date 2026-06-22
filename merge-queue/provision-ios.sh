#!/usr/bin/env bash
set -euo pipefail

: "${VZ_BIN:?}"
: "${BUNDLE:?}"
: "${STATE:?}"
ADMIN_PASS="${ADMIN_PASS:-vz}"
XCODE_APP="${XCODE_APP:-/Applications/Xcode.app}"

log() { printf '==> %s\n' "$*"; }
remote() { "$VZ_BIN" ssh "$BUNDLE" -- "$1"; }
rsudo() { printf '%s\n' "$ADMIN_PASS" | "$VZ_BIN" ssh "$BUNDLE" -- "sudo -S -p '' $1"; }

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
"$VZ_BIN" boot "$BUNDLE" >"$STATE/ios-boot.log" 2>&1 &
BOOT_PID=$!
wait_ssh || { echo "guest did not become SSH-reachable" >&2; exit 1; }

rsudo "xcode-select -s $XCODE_APP"

if remote "xcrun simctl list runtimes 2>/dev/null | grep -qi 'iOS '"; then
    log "iOS simulator runtime already installed"
else
    log "downloading iOS simulator runtime (multi-GB, slow)"
    remote "xcodebuild -downloadPlatform iOS"
fi

log "verifying an iPhone simulator is available"
remote "xcrun simctl list devices available | grep -i iPhone"

log "ios provisioning complete"
