#!/bin/bash
set -e
W=/tmp/w5; cd "$W"
SDK=$(xcrun --sdk macosx --show-sdk-path); TGT=arm64-apple-macos14.0
gen_target() { local d="$1" n="$2"; rm -rf "$d"; mkdir -p "$d/src" "$d/obj" "$d/stats"
  cat > "$d/src/View.swift" <<'SW'
import SwiftUI
struct CV: View { var body: some View { Text("edit me 0").padding(8) } }
SW
  awk -v n="$n" -v dd="$d" 'BEGIN{for(i=0;i<n;i++)printf "struct F%d { let a=%d; func g()->Int{a*2} }\n",i,i > ("/tmp/w5/"dd"/src/f"i".swift")}'
  { printf '{\n  "": {"swift-dependencies": "%s/obj/master.swiftdeps"}' "$d"
    for f in "$d"/src/*.swift; do b=$(basename "$f" .swift)
      printf ',\n  "%s": {"object": "%s/obj/%s.o", "swift-dependencies": "%s/obj/%s.swiftdeps"}' "$PWD/$f" "$d" "$b" "$d" "$b"
    done; printf '\n}\n'; } > "$d/ofm.json"; }
build() { local d="$1"; shift; swiftc -module-name M -c -incremental -enable-batch-mode \
  -output-file-map "$d/ofm.json" -sdk "$SDK" -target "$TGT" "$@" $(ls "$PWD/$d"/src/*.swift); }

echo "N  cold_s  inc_med_s  reemitted  typecheck_ms  irgen_ms"
for N in 100 250 500 1000; do
  d="t$N"; gen_target "$d" "$N"
  c0=$(date +%s.%N); build "$d" >/dev/null 2>"$d/cold.err"; c1=$(date +%s.%N)
  cold=$(echo "$c1-$c0"|bc)
  times=()
  for rep in 1 2 3; do
    stat -f '%m %N' "$d"/obj/*.o | sort > "$d/before.txt"
    perl -pi -e "s/edit me \\d+/edit me $rep/" "$d/src/View.swift"
    sleep 1
    extra=""; [ "$rep" = 1 ] && extra="-stats-output-dir $d/stats"
    t0=$(date +%s.%N); build "$d" $extra >/dev/null 2>"$d/inc.err"; t1=$(date +%s.%N)
    times+=("$(echo "$t1-$t0"|bc)")
    if [ "$rep" = 1 ]; then
      stat -f '%m %N' "$d"/obj/*.o | sort > "$d/after.txt"
      re=$(comm -13 "$d/before.txt" "$d/after.txt" | wc -l | tr -d ' ')
      sj=$(ls "$d"/stats/*.json 2>/dev/null | head -1)
      tc=$(grep -o '"time.swift.Sema.wall":[0-9]*' "$sj" 2>/dev/null | head -1 | cut -d: -f2)
      ir=$(grep -o '"time.swift.IRGen.wall":[0-9]*' "$sj" 2>/dev/null | head -1 | cut -d: -f2)
      [ -z "$tc" ] && tc=$(grep -o '"wall.Sema":[0-9.]*' "$sj" 2>/dev/null | head -1 | cut -d: -f2)
    fi
  done
  med=$(printf '%s\n' "${times[@]}" | sort -n | sed -n 2p)
  tcms=$([ -n "$tc" ] && echo "scale=1;${tc:-0}/1000000"|bc || echo NA)
  irms=$([ -n "$ir" ] && echo "scale=1;${ir:-0}/1000000"|bc || echo NA)
  echo "$N  $cold  $med  $re  $tcms  $irms"
done