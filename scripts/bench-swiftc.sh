#!/bin/bash
# bench-swiftc.sh — single-shot swiftc compile benchmark.
#
# Generates N chained Swift files (File_K depends on File_(K-1) so cascades
# fan out predictably), runs a clean cold build, then applies one edit and
# times the rebuild. Emits one CSV row per run.
#
# Used by bench-matrix.sh to populate a grid; can also be run standalone.
#
# Usage:
#   Scripts/bench-swiftc.sh \
#       --files 50 --mode wmo --threads 10 --edit body --runs 5
#
# Modes:
#   baseline    — -Onone -gnone (pre-#173 default)
#   wmo         — baseline + -wmo -num-threads N
#   incremental — baseline + -incremental + -output-file-map
#
# Edits (applied AFTER a cold build, then time the rebuild):
#   cold            — no edit; just measures the cold build
#   body            — body change in middle file (no interface change)
#   cascade-narrow  — interface change in second-to-last file (~2 files cascade)
#   cascade-wide    — interface change in middle file (~half cascade)
#   leaf            — body change in last file (no downstream dependents)
#   noop            — touch mtime only, no content change
set -euo pipefail

FILES=50
MODE=wmo
THREADS=$(sysctl -n hw.activeCPU 2>/dev/null || sysctl -n hw.ncpu)
EDIT=cold
RUNS=5
WORK=""
HEADER=1

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --files) FILES="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --edit) EDIT="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --work) WORK="$2"; shift 2 ;;
    --no-header) HEADER=0; shift ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac
done

case "$MODE" in baseline|wmo|incremental) ;; *) echo "bad --mode: $MODE" >&2; exit 2 ;; esac
case "$EDIT" in cold|body|cascade-narrow|cascade-wide|leaf|noop) ;; *) echo "bad --edit: $EDIT" >&2; exit 2 ;; esac

if [[ -z "$WORK" ]]; then
  WORK=$(mktemp -d -t bench-swiftc)
  trap 'rm -rf "$WORK"' EXIT
fi
SRC="$WORK/src"
BUILD="$WORK/build"
mkdir -p "$SRC" "$BUILD"

SDK=$(xcrun --show-sdk-path --sdk macosx)
SWIFTC=$(xcrun --find swiftc)
TARGET=$(uname -m)-apple-macos14.0

# Generate N chained Swift files. File_1 is a leaf; each File_K (K>1) depends
# on File_(K-1) so changing File_X's public interface cascades to File_(X+1)..N.
gen_sources() {
  local n=$1
  rm -rf "$SRC" && mkdir -p "$SRC"
  for k in $(seq 1 "$n"); do
    if [[ $k -eq 1 ]]; then
      cat >"$SRC/File_$k.swift" <<EOF
import Foundation
public struct Type_$k: Sendable {
    public let value: Int
    public init(value: Int) { self.value = value }
    public func describe() -> String { "Type_$k(\\(value))" }
}
public func make_$k() -> Type_$k { Type_$k(value: $k) }
EOF
    else
      local prev=$((k - 1))
      cat >"$SRC/File_$k.swift" <<EOF
import Foundation
public struct Type_$k: Sendable {
    public let prev: Type_$prev
    public let value: Int
    public init(prev: Type_$prev, value: Int) { self.prev = prev; self.value = value }
    public func describe() -> String { "Type_$k(\\(value)) <- \\(prev.describe())" }
}
public func make_$k() -> Type_$k { Type_$k(prev: make_$prev(), value: $k) }
EOF
    fi
  done
}

# Generate output-file-map.json (used only in incremental mode).
gen_fmap() {
  local fmap="$BUILD/output-file-map.json"
  {
    echo '{'
    echo '  "": {'
    echo "    \"swift-dependencies\": \"$BUILD/master.swiftdeps\""
    echo '  },'
    local first=1
    for f in "$SRC"/*.swift; do
      local base
      base=$(basename "$f" .swift)
      if [[ $first -eq 1 ]]; then first=0; else echo ','; fi
      cat <<EOF
  "$f": {
    "object": "$BUILD/$base.o",
    "swift-dependencies": "$BUILD/$base.swiftdeps",
    "swiftmodule": "$BUILD/$base.partial.swiftmodule"
  }
EOF
    done
    echo
    echo '}'
  } >"$fmap"
}

# Compose the swiftc invocation for the active mode.
swiftc_args() {
  local args=(
    "$SWIFTC"
    -emit-library
    -parse-as-library
    -target "$TARGET"
    -sdk "$SDK"
    -module-name Bench
    -Onone
    -gnone
  )
  case "$MODE" in
    wmo)
      args+=(-wmo -num-threads "$THREADS")
      ;;
    incremental)
      args+=(-incremental -output-file-map "$BUILD/output-file-map.json" -driver-show-job-lifecycle)
      ;;
  esac
  args+=(-o "$BUILD/libBench.dylib")
  for f in "$SRC"/*.swift; do args+=("$f"); done
  printf '%s\n' "${args[@]}"
}

# Apply the configured edit to the source tree. Idempotent — each run mutates
# a unique file/spot using $i so repeated runs keep producing real changes.
apply_edit() {
  local i=$1
  case "$EDIT" in
    cold) : ;;
    body)
      local mid=$((FILES / 2))
      perl -i -pe "s/Type_${mid}\\(value\\)/Type_${mid}(value+0+$i)/" "$SRC/File_${mid}.swift"
      ;;
    cascade-narrow)
      local target=$((FILES - 1))
      perl -i -pe "s/(public func describe)/public func bench_${i}() -> Int { $i }\n    \$1/" "$SRC/File_${target}.swift"
      ;;
    cascade-wide)
      local mid=$((FILES / 2))
      perl -i -pe "s/(public func describe)/public func bench_${i}() -> Int { $i }\n    \$1/" "$SRC/File_${mid}.swift"
      ;;
    leaf)
      perl -i -pe "s/Type_${FILES}\\(value\\)/Type_${FILES}(value+0+$i)/" "$SRC/File_${FILES}.swift"
      ;;
    noop)
      local mid=$((FILES / 2))
      touch "$SRC/File_${mid}.swift"
      ;;
  esac
}

# Run swiftc and capture wall time + frontend job count. Echoes "wall jobs".
run_once() {
  local stderr_file="$BUILD/last.stderr"
  local args
  IFS=$'\n' read -r -d '' -a args < <(swiftc_args && printf '\0') || true
  local t0 t1
  t0=$(python3 -c 'import time; print(time.monotonic())')
  "${args[@]}" 2>"$stderr_file"
  t1=$(python3 -c 'import time; print(time.monotonic())')
  local wall
  wall=$(python3 -c "print(f'{$t1 - $t0:.3f}')")
  local jobs
  if [[ "$MODE" == incremental ]]; then
    jobs=$(grep -c "Starting Compiling" "$stderr_file" || true)
  else
    jobs=1
  fi
  printf '%s %s\n' "$wall" "$jobs"
}

# Emit CSV header unless suppressed (for matrix runs).
if [[ $HEADER -eq 1 ]]; then
  echo "mode,files,threads,edit,run,wall_seconds,frontend_jobs"
fi

# Generate fresh sources for the whole batch. Each run gets a fresh cold build
# (rm -rf build) so timings are independent of prior incremental state.
gen_sources "$FILES"

for run in $(seq 1 "$RUNS"); do
  rm -rf "$BUILD" && mkdir -p "$BUILD"
  if [[ "$MODE" == incremental ]]; then gen_fmap; fi

  # Cold build (always — establishes the baseline state for the edit).
  read -r _cold_wall _cold_jobs < <(run_once)

  if [[ "$EDIT" == cold ]]; then
    echo "$MODE,$FILES,$THREADS,$EDIT,$run,$_cold_wall,$_cold_jobs"
    # Regenerate sources so each subsequent run starts from a clean slate.
    gen_sources "$FILES"
    continue
  fi

  apply_edit "$run"
  read -r wall jobs < <(run_once)
  echo "$MODE,$FILES,$THREADS,$EDIT,$run,$wall,$jobs"

  # Reset sources between runs so cumulative edits don't drift the workload.
  gen_sources "$FILES"
done
