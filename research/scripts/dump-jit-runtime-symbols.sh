#!/usr/bin/env bash
# Dump every symbol exported by the JIT-runtime-side binaries:
# - libPreviewsJITStubExecutor.a — host-side static archive linked into
#   the agent. Contains the JIT-link entrypoints + the runtime that
#   actually executes the agent's per-update link step.
# - PreviewsInjection.framework — device-side framework injected via
#   DYLD_INSERT_LIBRARIES. The host has only a .tbd stub (public
#   surface); the real binary lives inside the VM's dyld shared cache.
#
# Resolves Open Question 6 from architecture-diagram-draft.md ("Does
# the agent's JIT linker actually use LLVM ORC, or a private fork?")
# by searching for llvm::orc::* symbols. ORC internals are C++ — we
# c++filt the nm output and grep for the namespace.
#
# Both binaries are arm64+x86_64+arm64e fat. We only dump the arm64
# slice (matches the post-xcode-sip-amfi VM). For broader coverage,
# loop over arches by uncommenting the inner loop.

set -euo pipefail

XCODE_APP="${XCODE_APP:-/Applications/Xcode-26.2.0.app}"
OUT_DIR="${0%/*}/data"
mkdir -p "$OUT_DIR"

if [[ ! -d "$XCODE_APP" ]]; then
    echo "Xcode.app not found at $XCODE_APP" >&2; exit 1
fi

# --- libPreviewsJITStubExecutor.a (host static archive) -------------

A_FILE="$XCODE_APP/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/libPreviewsJITStubExecutor.a"
if [[ ! -f "$A_FILE" ]]; then
    echo "libPreviewsJITStubExecutor.a missing at $A_FILE" >&2; exit 1
fi

TMP=$(mktemp -d -t previewsvm-jit)
trap 'rm -rf "$TMP"' EXIT

echo "==> Thinning libPreviewsJITStubExecutor.a (arm64 slice)..." >&2
lipo -thin arm64 "$A_FILE" -output "$TMP/jitexec-arm64.a"

# nm -gU = global, exported, no undefined. The archive contains many
# .o members; nm walks them.
# Demangle Swift first, then any remaining C++ symbols via xcrun
# c++filt (Apple's lib clang-internal demangler is available via the
# Swift toolchain's c++filt; fall back to system c++filt).
echo "==> Dumping libPreviewsJITStubExecutor.a symbols..." >&2
xcrun nm -gU "$TMP/jitexec-arm64.a" \
    | xcrun swift-demangle \
    | (xcrun c++filt 2>/dev/null || c++filt) \
    | sort -u \
    > "$OUT_DIR/libPreviewsJITStubExecutor-symbols.txt"

A_COUNT=$(wc -l < "$OUT_DIR/libPreviewsJITStubExecutor-symbols.txt" | tr -d ' ')
echo "    → $OUT_DIR/libPreviewsJITStubExecutor-symbols.txt ($A_COUNT lines)" >&2

# --- PreviewsInjection.framework.tbd (host stub) --------------------

TBD="$XCODE_APP/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks/PreviewsInjection.framework/Versions/A/PreviewsInjection.tbd"
if [[ ! -f "$TBD" ]]; then
    echo "PreviewsInjection.tbd missing at $TBD" >&2; exit 1
fi

echo "==> Extracting + demangling PreviewsInjection.tbd public symbols..." >&2
# TBD files are TAPI YAML. The `symbols:` arrays under `exports:` carry
# bare mangled names (each entry like `'_$sFooBar'`). Grep out the
# quoted strings, normalize one per line, demangle.
grep -oE "'[^']+'" "$TBD" \
    | tr -d "'" \
    | grep -E "^[_$].+" \
    | xcrun swift-demangle \
    | (xcrun c++filt 2>/dev/null || c++filt) \
    | sort -u \
    > "$OUT_DIR/PreviewsInjection-tbd-symbols.txt"

TBD_COUNT=$(wc -l < "$OUT_DIR/PreviewsInjection-tbd-symbols.txt" | tr -d ' ')
echo "    → $OUT_DIR/PreviewsInjection-tbd-symbols.txt ($TBD_COUNT lines)" >&2

# --- Q6 quick check: llvm::orc::* presence --------------------------

echo "==> Open Question 6 check: 'llvm::orc::*' presence in JIT runtime" >&2
HITS_A=$(grep -c 'llvm::orc' "$OUT_DIR/libPreviewsJITStubExecutor-symbols.txt" || true)
HITS_T=$(grep -c 'llvm::orc' "$OUT_DIR/PreviewsInjection-tbd-symbols.txt" || true)
echo "    libPreviewsJITStubExecutor.a:  $HITS_A llvm::orc:: matches" >&2
echo "    PreviewsInjection.tbd:         $HITS_T llvm::orc:: matches" >&2

# Also surface broader LLVM/JITLink markers — Apple may use a non-orc
# namespace or have renamed it.
echo "==> Broader marker scan (llvm::, JIT, JITLink, ORC, RuntimeDyld)" >&2
{
    echo "## libPreviewsJITStubExecutor.a markers"
    for marker in 'llvm::' 'orc::' 'JITLink' 'RuntimeDyld' 'jitlink' 'XOJIT' 'pseudodylib' 'pseudoDylib'; do
        count=$(grep -ic -- "$marker" "$OUT_DIR/libPreviewsJITStubExecutor-symbols.txt" || true)
        printf '  %-20s %d\n' "$marker" "$count"
    done
    echo
    echo "## PreviewsInjection.tbd markers"
    for marker in 'llvm::' 'orc::' 'JITLink' 'RuntimeDyld' 'jitlink' 'XOJIT' 'pseudodylib' 'pseudoDylib'; do
        count=$(grep -ic -- "$marker" "$OUT_DIR/PreviewsInjection-tbd-symbols.txt" || true)
        printf '  %-20s %d\n' "$marker" "$count"
    done
} > "$OUT_DIR/jit-runtime-markers.txt"
cat "$OUT_DIR/jit-runtime-markers.txt" >&2

echo "==> Done. Detailed dumps + marker summary in $OUT_DIR/" >&2
