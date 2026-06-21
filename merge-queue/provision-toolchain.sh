#!/usr/bin/env bash
set -euo pipefail

: "${VZ_BIN:?}"
: "${BUNDLE:?}"
: "${XCODE_VER:?}"
: "${STATE:?}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-vz}"
XCODE_XIP="${XCODE_XIP:-}"
XIP_CACHE="${XIP_CACHE:-$HOME/.cache/merge-queue/xcode}"

log() { printf '==> %s\n' "$*"; }

resolve_xip() {
    if [ -n "$XCODE_XIP" ]; then
        [ -f "$XCODE_XIP" ] || { echo "XCODE_XIP not found: $XCODE_XIP" >&2; exit 1; }
        XIP="$XCODE_XIP"
        return
    fi
    mkdir -p "$XIP_CACHE"
    XIP="$(ls "$XIP_CACHE"/Xcode*"$XCODE_VER"*.xip 2>/dev/null | head -1 || true)"
    if [ -z "$XIP" ]; then
        command -v xcodes >/dev/null || { echo "no XCODE_XIP and xcodes not installed (brew install xcodes)" >&2; exit 1; }
        log "xcodes download $XCODE_VER (Apple auth + 2FA on first run)"
        xcodes download "$XCODE_VER" --directory "$XIP_CACHE"
        XIP="$(ls "$XIP_CACHE"/Xcode-"$XCODE_VER"*.xip | head -1)"
    fi
}

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

resolve_xip
log "using xip: $XIP"

log "booting guest"
"$VZ_BIN" boot "$BUNDLE" >"$STATE/toolchain-boot.log" 2>&1 &
BOOT_PID=$!
wait_ssh || { echo "guest did not become SSH-reachable" >&2; exit 1; }

log "streaming xip into guest"
"$VZ_BIN" ssh "$BUNDLE" -- "cat > /tmp/Xcode.xip" < "$XIP"

log "expanding Xcode in guest"
remote "cd /tmp && rm -rf Xcode.app && xip -x Xcode.xip"
rsudo "rm -rf /Applications/Xcode.app && mv /tmp/Xcode.app /Applications/Xcode.app"
remote "rm -f /tmp/Xcode.xip"

log "selecting toolchain and accepting license"
rsudo "xcode-select -s /Applications/Xcode.app"
rsudo "xcodebuild -license accept"
rsudo "xcodebuild -runFirstLaunch"

log "installing Homebrew, bazelisk, mise"
remote 'NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
remote 'eval "$(/opt/homebrew/bin/brew shellenv)" && brew install bazelisk mise'

log "enabling autologin for $ADMIN_USER"
rsudo "sysadminctl -autologin set -userName $ADMIN_USER -password $ADMIN_PASS"

log "verifying swift toolchain in guest"
remote "xcrun swift --version"

log "toolchain provisioning complete"
