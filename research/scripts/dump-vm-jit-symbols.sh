#!/usr/bin/env bash
# Dump VM-side symbol info for PreviewsInjection + XOJITExecutor.
#
# Resolves the remaining VM-side gap in Q6 (per
# analysis/q6-jit-runtime-findings.md): the actual framework
# binaries on the device live inside the dyld shared cache and
# aren't on the host filesystem. `dyld_info` against the
# in-cache paths reveals linked_dylibs / imports / exports the
# host can't see from the .tbd stub alone.
#
# Assumes: a `post-xcode-sip-amfi`-style bundle is currently
# booted and reachable via `previewsvm ssh`.

set -euo pipefail

BUNDLE="${PREVIEWSVM_BUNDLE:-/tmp/verify.bundle}"
PREVIEWSVM="${PREVIEWSVM:-${0%/*}/../vm/.build/release/previewsvm}"
OUT_DIR="${0%/*}/data/vm"
mkdir -p "$OUT_DIR"

if ! "$PREVIEWSVM" status "$BUNDLE" 2>/dev/null | grep -q "DHCP lease:       192"; then
    echo "VM not booted (no DHCP lease for $BUNDLE)." >&2
    echo "Run: $PREVIEWSVM boot $BUNDLE --skip-ssh-wait &" >&2
    exit 1
fi

dump() {
    local label="$1" framework_path="$2"
    echo "==> $label" >&2

    "$PREVIEWSVM" ssh "$BUNDLE" "xcrun dyld_info -linked_dylibs '$framework_path'" \
        > "$OUT_DIR/${label}-linked_dylibs.txt"
    "$PREVIEWSVM" ssh "$BUNDLE" "xcrun dyld_info -imports '$framework_path'" \
        > "$OUT_DIR/${label}-imports.txt"
    "$PREVIEWSVM" ssh "$BUNDLE" "xcrun dyld_info -exports '$framework_path' | xcrun swift-demangle" \
        | sort -u \
        > "$OUT_DIR/${label}-exports.txt"

    local imp_count exp_count
    imp_count=$(wc -l < "$OUT_DIR/${label}-imports.txt" | tr -d ' ')
    exp_count=$(wc -l < "$OUT_DIR/${label}-exports.txt" | tr -d ' ')
    echo "    imports: $imp_count  exports: $exp_count" >&2
}

dump "PreviewsInjection" "/System/Library/PrivateFrameworks/PreviewsInjection.framework/PreviewsInjection"
dump "XOJITExecutor"     "/System/Library/PrivateFrameworks/XOJITExecutor.framework/Versions/A/XOJITExecutor"

# Q6 marker scan: look for explicit LLVM / ORC / JITLink signatures
# in the combined symbol surface.
echo "==> Q6 marker scan across PreviewsInjection + XOJITExecutor" >&2
{
    echo "## Markers in PreviewsInjection + XOJITExecutor"
    echo
    for label in PreviewsInjection XOJITExecutor; do
        echo "### $label"
        for marker in 'llvm_orc_' 'jit_debug' 'JITDylib' 'JITLink' 'pseudodylib' 'XOJIT' 'orc::' 'llvm::'; do
            for file in "$OUT_DIR/${label}-imports.txt" "$OUT_DIR/${label}-exports.txt"; do
                count=$(grep -ic -- "$marker" "$file" 2>/dev/null || true)
                if (( count > 0 )); then
                    printf '  %-30s %-15s %d\n' "$marker" "${file##*/}" "$count"
                fi
            done
        done
        echo
    done
} > "$OUT_DIR/q6-vm-markers.txt"
cat "$OUT_DIR/q6-vm-markers.txt" >&2

echo "==> Done. Data in $OUT_DIR/" >&2
