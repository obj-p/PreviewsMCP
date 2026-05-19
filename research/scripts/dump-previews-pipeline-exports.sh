#!/usr/bin/env bash
# Dump every exported symbol of PreviewsPipeline.framework, swift-demangled.
#
# The spike's first concrete W2 deliverable
# (prompts/jit-executor-research.md, LT-1): we want to know which step
# types Apple's preview pipeline ships so we can map each to a
# public-layer analogue we'd build ourselves. dyld_info -exports gives
# us the framework's public Mach-O symbol table; xcrun swift-demangle
# turns the Swift-mangled names into readable signatures.
#
# Runs inside the research VM via `previewsvm ssh`. Writes the
# demangled, sorted export list to stdout; status to stderr. Re-running
# is idempotent.

set -euo pipefail

BUNDLE="${PREVIEWSVM_BUNDLE:-/tmp/verify.bundle}"
PREVIEWSVM="${PREVIEWSVM:-${0%/*}/../vm/.build/release/previewsvm}"

if [[ ! -x "$PREVIEWSVM" ]]; then
    echo "previewsvm binary not found or not executable at $PREVIEWSVM" >&2
    echo "Set PREVIEWSVM env var or build research/vm/ first." >&2
    exit 1
fi

if ! "$PREVIEWSVM" status "$BUNDLE" 2>/dev/null | grep -q "DHCP lease:       192"; then
    echo "VM not booted (no DHCP lease for $BUNDLE)." >&2
    echo "Run: $PREVIEWSVM boot $BUNDLE --skip-ssh-wait &" >&2
    exit 1
fi

echo "==> Listing PreviewsPipeline.framework exports from inside the VM..." >&2

# Locate the framework (path can shift between Xcode majors), then
# dyld_info -exports each Mach-O slice. swift-demangle understands
# `_$s...` Swift mangled prefixes and rewrites them in place.
"$PREVIEWSVM" ssh "$BUNDLE" '
    set -eu
    FW="/Applications/Xcode.app/Contents/SharedFrameworks/PreviewsPipeline.framework/Versions/A/PreviewsPipeline"
    if [ ! -f "$FW" ]; then
        echo "PreviewsPipeline binary not at $FW" >&2
        exit 1
    fi
    xcrun dyld_info -exports "$FW" | xcrun swift-demangle | sort -u
'
