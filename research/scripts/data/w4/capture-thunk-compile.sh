#!/bin/bash
# W4 open item — capture the Xcode Previews thunk-compile swift-frontend argv.
#
# The preview build service compiles the per-file thunk out-of-band (not in
# DerivedData/Logs/Build, no persisted response file), so the exact argv must
# be caught while it runs. This is sudo-free: it polls `ps` for swiftc /
# swift-frontend processes whose argv mentions a preview thunk, and appends any
# new full command line it sees. (fs_usage/dtrace would be lower-overhead but
# need root; ps polling needs nothing.)
#
# Usage (fixture flow — see preview-fixture/README.md):
#   1. cd preview-fixture && xcodegen generate && xed PreviewFixture.xcodeproj
#      Show the canvas for ContentView's #Preview, wait for the first render.
#   2. Run this script:  ./capture-thunk-compile.sh [seconds]   (default 60)
#   3. While it runs, change ONE literal in the previewed View's body and save.
#      Repeat the edit a couple times so a short-lived frontend is caught.
#   4. The captured command lines land in w4-thunk-argv.txt next to this script.

DUR="${1:-60}"
OUT="$(cd "$(dirname "$0")" && pwd)/w4-thunk-argv.txt"
: > "$OUT"
echo "polling ps for ${DUR}s — make a one-literal body edit in the canvas now"
END=$(( $(date +%s) + DUR ))
seen=""
while [ "$(date +%s)" -lt "$END" ]; do
  # -ww = no width truncation; capture full argv. Anchor on the executable being
  # swift-frontend/swiftc (first token), so a shell that merely mentions those
  # words in its argv is not matched.
  while IFS= read -r line; do
    exe="${line%% *}"
    case "$exe" in
      */swift-frontend|*/swiftc) ;;
      *) continue ;;
    esac
    case "$line" in
      *preview-thunk*|*__designTime*|*vfsoverlay*|*XCPREVIEW*)
        key=$(echo "$line" | md5)
        case "$seen" in
          *"$key"*) ;;
          *) seen="$seen $key"
             { echo "=== $(date +%T) ==="; echo "$line"; echo; } >> "$OUT"
             echo "captured a thunk compile -> $OUT" ;;
        esac
        ;;
    esac
  done < <(ps -axww -o command= 2>/dev/null)
done
echo "done. $(grep -c '^===' "$OUT") capture(s) in $OUT"
