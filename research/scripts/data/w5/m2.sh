#!/bin/bash
set -e
W=/tmp/w5; cd "$W"
SDK=$(xcrun --sdk macosx --show-sdk-path); TGT=arm64-apple-macos14.0
N=200
build() { local d="$1"; swiftc -module-name M -c -incremental -enable-batch-mode \
  -output-file-map "$d/ofm.json" -sdk "$SDK" -target "$TGT" $(ls "$PWD/$d"/src/*.swift) >/dev/null 2>"$d/err"; }
echo "K  edit_kind        reemitted_objects"
for K in 1 10 50; do
  d="fan$K"; rm -rf "$d"; mkdir -p "$d/src" "$d/obj"
  # shared decl referenced by K files
  cat > "$d/src/Shared.swift" <<'SW'
public struct Shared { public static func compute() -> Int { 0 } }
SW
  for i in $(seq 1 "$K"); do echo "struct D$i { func use() -> Int { Shared.compute() } }" > "$d/src/d$i.swift"; done
  # independent filler up to N
  fill=$((N - K - 1)); for i in $(seq 1 "$fill"); do echo "struct F$i { let a=$i }" > "$d/src/f$i.swift"; done
  { printf '{\n  "": {"swift-dependencies": "%s/obj/master.swiftdeps"}' "$d"
    for f in "$d"/src/*.swift; do b=$(basename "$f" .swift)
      printf ',\n  "%s": {"object": "%s/obj/%s.o", "swift-dependencies": "%s/obj/%s.swiftdeps"}' "$PWD/$f" "$d" "$b" "$d" "$b"
    done; printf '\n}\n'; } > "$d/ofm.json"
  build "$d"
  # body-local edit (change the literal inside compute): expect 1
  stat -f '%m %N' "$d"/obj/*.o | sort > "$d/b.txt"
  perl -pi -e 's/compute\(\) -> Int \{ \d+ \}/"compute() -> Int { ".(int(rand(900))+1)." }"/e' "$d/src/Shared.swift"; sleep 1
  build "$d"; stat -f '%m %N' "$d"/obj/*.o | sort > "$d/a.txt"
  echo "$K  body-local       $(comm -13 "$d/b.txt" "$d/a.txt" | wc -l | tr -d ' ')"
  # interface edit (add a defaulted param -> callers still compile, dependents recompile): expect 1+K
  stat -f '%m %N' "$d"/obj/*.o | sort > "$d/b2.txt"
  perl -pi -e 's/static func compute\([^)]*\)/"static func compute(_ x: Int = ".(int(rand(900))+1).")"/e' "$d/src/Shared.swift"; sleep 1
  build "$d"; stat -f '%m %N' "$d"/obj/*.o | sort > "$d/a2.txt"
  echo "$K  interface-change $(comm -13 "$d/b2.txt" "$d/a2.txt" | wc -l | tr -d ' ')"
done