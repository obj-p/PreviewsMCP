#!/usr/bin/env bash
# bake.sh — build the VM snapshot ladder the Previews-RE reproductions restore.
#
# Ladder: install -> post-sa -> post-sip -> post-amfi -> post-xcode.
# Runs under `caffeinate -dimsu` (lid open, plugged in) and logs to a file.
# Each step is guarded by snapshot existence, so an interrupted/failed run
# resumes from where it stopped — re-invoke and completed rungs are skipped.
#
# ATTENDED, laptop-bound. The READY rungs are one-command via vzy. The unported
# rungs (post-sip / post-amfi / post-xcode) are STUBS: the recoveryOS RFB,
# boot-args, Xcode-install, and GUI-drive automation were NOT extracted into
# vzy — they live only in archive/previews-research-3201
# research/vm/.../SetupCommand.swift. They are ported INCREMENTALLY here,
# verified against the live VM one rung at a time (do NOT blind-write them).
#
# Usage:
#   VZY_BUNDLE=~/VMs/previews.bundle ./bake.sh            # resumes the ladder
#   VZY_BUNDLE=... IPSW=~/ipsw/UniversalMac_26.2.ipsw ./bake.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VZY="${VZY:-$HOME/Projects/vzy/.build/release/vzy}"
BUNDLE="${VZY_BUNDLE:?set VZY_BUNDLE to the target vz bundle path}"
IPSW="${IPSW:-latest}"
LOG="${LOG:-/tmp/vzy-bake-$(date +%s 2>/dev/null || echo run).log}"

[[ -x "$VZY" ]] || { echo "FATAL: vzy not built at $VZY (build.sh in ~/Projects/vzy)" >&2; exit 1; }

have_snapshot() { "$VZY" snapshot list "$BUNDLE" 2>/dev/null | grep -qx "$1"; }

# rung <snapshot> <human-desc> -- <command...>
# Skips if <snapshot> already exists; else runs the command and snapshots.
rung() {
    local snap="$1" desc="$2"; shift 2
    [[ "$1" == "--" ]] && shift
    if have_snapshot "$snap"; then
        echo "[bake] SKIP  ${snap} (${desc}) — already present"
        return 0
    fi
    echo "[bake] RUN   ${snap} (${desc})"
    if ! "$@"; then
        echo "[bake] FAIL  ${snap} (${desc}) — fix and re-run bake.sh to resume" >&2
        exit 1
    fi
    "$VZY" snapshot take "$BUNDLE" "$snap"
    echo "[bake] DONE  ${snap}"
}

stub() {
    echo "[bake] STUB  $1 — NOT YET PORTED from archive previews-research-3201." >&2
    echo "            Port the '$2' automation against the live VM this session," >&2
    echo "            then replace this stub with the real rung. See README.md." >&2
    exit 2
}

bake() {
    echo "[bake] bundle=${BUNDLE} ipsw=${IPSW} log=${LOG}"

    # -- READY rungs (one-command via extracted vzy) ----------------------
    if [[ ! -d "$BUNDLE" ]]; then
        echo "[bake] RUN   install (${IPSW})"
        "$VZY" install "$BUNDLE" --ipsw "$IPSW" || { echo "[bake] FAIL install" >&2; exit 1; }
    fi
    rung post-sa "Setup Assistant complete + SSH provisioned" -- \
        "$VZY" setup "$BUNDLE" --preset provision-ssh --invisible

    # -- UNPORTED rungs (incremental port against the live VM) ------------
    have_snapshot post-sip   || stub post-sip   "disable-sip (recoveryOS csrutil via RFB)"
    have_snapshot post-amfi  || stub post-amfi  "amfi off (nvram boot-args=amfi_get_out_of_my_way=1)"
    have_snapshot post-xcode || stub post-xcode "Xcode install + first-launch"

    echo "[bake] LADDER COMPLETE — post-xcode ready for the reproductions."
}

# Keep the machine awake for the whole bake and tee everything to the log.
# Export the config so the caffeinate sub-shell (which only receives the
# function bodies via declare -f) inherits it through the environment.
export VZY BUNDLE IPSW LOG
exec caffeinate -dimsu bash -c "$(declare -f have_snapshot rung stub bake); bake" 2>&1 | tee "$LOG"
