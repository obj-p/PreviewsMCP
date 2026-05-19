#!/usr/bin/env bash
# Dump every exported symbol of the 11 PreviewsPipeline sibling
# frameworks, swift-demangled.
#
# Companion to dump-previews-pipeline-exports.sh. Where that script
# dumps PreviewsPipeline itself, this one dumps the 11 frameworks it
# ships alongside in Xcode.app/Contents/SharedFrameworks/. Per the
# spike doc (prompts/jit-executor-research.md, LT-1) and the existing
# RE doc (docs/reverse-engineering.md:107-122 + 717-719), there are
# 12 host-side Previews frameworks total — one for the primary
# pipeline and 11 for support layers (Foundation, Messaging, UI,
# Model, etc).
#
# These are the same Xcode-version-pinned binaries we tar'd into the
# VM for post-xcode-sip-amfi — running on the host avoids a VM boot
# and produces identical bytes. The script will fall back to the
# bundled VM Xcode if XCODE_APP isn't set and the host Xcode isn't
# at /Applications/Xcode-26.2.0.app.

set -euo pipefail

XCODE_APP="${XCODE_APP:-/Applications/Xcode-26.2.0.app}"

if [[ ! -d "$XCODE_APP/Contents/SharedFrameworks" ]]; then
    echo "Xcode.app not found at $XCODE_APP/Contents/SharedFrameworks" >&2
    echo "Set XCODE_APP env var to override." >&2
    exit 1
fi

OUT_DIR="${0%/*}/data"
mkdir -p "$OUT_DIR"

# The 12 frameworks per docs/reverse-engineering.md:717-719. We skip
# PreviewsPipeline itself (covered by dump-previews-pipeline-exports.sh
# in a separate file so the diffs stay readable).
FRAMEWORKS=(
    PreviewsFoundationHost
    PreviewsMessagingHost
    PreviewsModel
    PreviewsSyntax
    PreviewsUI
    PreviewsDeveloperTools
    PreviewsScenes
    PreviewsXcodeUI
    PreviewsPlatforms
    PreviewsXROSMessaging
    PreviewsXROSServices
)

echo "==> Dumping exports for ${#FRAMEWORKS[@]} PreviewsPipeline sibling frameworks" >&2
echo "    Xcode bundle: $XCODE_APP" >&2
echo "    Output dir:   $OUT_DIR" >&2

for name in "${FRAMEWORKS[@]}"; do
    binary="$XCODE_APP/Contents/SharedFrameworks/${name}.framework/Versions/A/${name}"
    if [[ ! -f "$binary" ]]; then
        echo "    [skip] $name — binary missing at $binary" >&2
        continue
    fi
    out_file="$OUT_DIR/${name}-exports.txt"
    xcrun dyld_info -exports "$binary" \
        | xcrun swift-demangle \
        | sort -u \
        > "$out_file"
    line_count=$(wc -l < "$out_file" | tr -d ' ')
    echo "    [dump] $name → ${out_file##*/}  ($line_count symbols)" >&2
done

echo "==> Done" >&2
