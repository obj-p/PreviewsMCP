#!/usr/bin/env bash
# Manual smoke test for issue #125 inline snapshot rendering.
#
# Emits an iTerm2 OSC 1337 inline-image escape (DCS-wrapped if running
# inside tmux) for a PNG. Uses Sources/PreviewsIOS/AppIcon.png by default.
#
# If you see the icon rendered in your terminal, your setup supports
# inline rendering and `previewsmcp snapshot` will render inline too.
# If you see base64 garbage or nothing, your terminal doesn't support
# the protocol — `previewsmcp snapshot` will fall back to path-only.
#
# Usage:
#   scripts/test-inline-image.sh [path-to-png]
#
# tmux caveat:
#   Inside tmux this script emits the DCS passthrough envelope, but tmux
#   still discards it unless `allow-passthrough` is on. Enable with:
#     tmux set -g allow-passthrough on
#   and re-run. Revert with `tmux set -g allow-passthrough off` when done.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMG="${1:-${REPO_ROOT}/Sources/PreviewsIOS/AppIcon.png}"

if [[ ! -f "$IMG" ]]; then
    echo "error: image not found: $IMG" >&2
    exit 1
fi

SIZE=$(wc -c < "$IMG" | tr -d ' ')
B64=$(base64 < "$IMG" | tr -d '\n')

if [[ -n "${TMUX:-}" ]]; then
    PT=$(tmux show-options -gv allow-passthrough 2>/dev/null || echo "unknown")
    if [[ "$PT" != "on" && "$PT" != "all" ]]; then
        echo "note: inside tmux with allow-passthrough=${PT}; enable with:" >&2
        echo "        tmux set -g allow-passthrough on" >&2
    fi
    printf '\033Ptmux;\033\033]1337;File=inline=1;size=%s:%s\007\033\\' "$SIZE" "$B64"
else
    printf '\033]1337;File=inline=1;size=%s:%s\007' "$SIZE" "$B64"
fi
printf '\n'
