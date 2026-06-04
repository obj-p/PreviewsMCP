#!/bin/bash
set -e
W=/tmp/w5; cd "$W"
SDK=$(xcrun --sdk macosx --show-sdk-path); TGT=arm64-apple-macos14.0
echo "N  bulk_build_s  view_inc_med_s  reemitted"
for N in 100 250 500 1000; do
  d="s$N"; rm -rf "$d"; mkdir -p "$d/bulk" "$d/view" "$d/bmod" "$d/vobj"
  awk -v n="$N" -v dd="$d" 'BEGIN{for(i=0;i<n;i++)printf "public struct F%d { public let a=%d; public func g()->Int{a*2} }\n",i,i > ("/tmp/w5/"dd"/bulk/f"i".swift")}'
  cat > "$d/view/View.swift" <<'SW'
import SwiftUI
import Bulk
struct CV: View { var body: some View { Text("edit me 0").padding(8) } }
SW
  # build bulk as a prebuilt .swiftmodule (one-time cost, not per-edit)
  b0=$(date +%s.%N)
  swiftc -module-name Bulk -emit-module -emit-module-path "$d/bmod/Bulk.swiftmodule" \
    -c -o /dev/null -sdk "$SDK" -target "$TGT" $(ls "$PWD/$d"/bulk/*.swift) >/dev/null 2>"$d/bulk.err" || {
      # -o /dev/null with -c multi-file not allowed; emit objects to dir instead
      swiftc -module-name Bulk -emit-module -emit-module-path "$d/bmod/Bulk.swiftmodule" \
        -emit-object -output-file-map <(printf '{}') -sdk "$SDK" -target "$TGT" $(ls "$PWD/$d"/bulk/*.swift) >/dev/null 2>"$d/bulk.err" || true
      swiftc -module-name Bulk -emit-module -emit-module-path "$d/bmod/Bulk.swiftmodule" \
        -sdk "$SDK" -target "$TGT" $(ls "$PWD/$d"/bulk/*.swift) >/dev/null 2>"$d/bulk.err"; }
  b1=$(date +%s.%N)
  # cold-compile the view against prebuilt module
  vbuild() { swiftc -module-name V -c "$PWD/$d/view/View.swift" \
    -I "$PWD/$d/bmod" -sdk "$SDK" -target "$TGT" -o "$d/vobj/View.o"; }
  vbuild
  times=()
  for rep in 1 2 3; do
    m0=$(stat -f '%m' "$d/vobj/View.o")
    perl -pi -e "s/edit me \\d+/edit me $rep/" "$d/view/View.swift"; sleep 1
    t0=$(date +%s.%N); vbuild; t1=$(date +%s.%N); times+=("$(echo "$t1-$t0"|bc)")
    m1=$(stat -f '%m' "$d/vobj/View.o"); [ "$rep" = 1 ] && { [ "$m1" != "$m0" ] && re=1 || re=0; }
  done
  med=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 2p)
  echo "$N  $(echo "$b1-$b0"|bc)  $med  $re"
done