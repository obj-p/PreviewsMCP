#!/bin/bash
# bench-matrix.sh — run a grid of bench-swiftc.sh cells and emit a Markdown
# table summarizing p50 + p95 wall time and median frontend job count.
#
# By default, runs a sensible exploratory grid that fits in a few minutes:
#   modes: baseline, wmo, incremental
#   files: 50, 200
#   edits: cold, body, cascade-wide, leaf, noop
#   wmo threads: activeProcessorCount
#   runs: 5
#
# Override the grid via env vars:
#   MODES, FILES, EDITS, THREADS, RUNS — space-separated lists.
#
# Output is written to stdout as Markdown. Raw CSV is also written to
# $OUT_CSV (default: bench-results.csv) so you can re-aggregate later.
#
# Usage:
#   Scripts/bench-matrix.sh
#   MODES="wmo incremental" FILES="50 200 500" Scripts/bench-matrix.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BENCH="$HERE/bench-swiftc.sh"

MODES="${MODES:-baseline wmo incremental}"
FILES="${FILES:-50 200}"
EDITS="${EDITS:-cold body cascade-wide leaf noop}"
THREADS="${THREADS:-$(sysctl -n hw.activeCPU 2>/dev/null || sysctl -n hw.ncpu)}"
RUNS="${RUNS:-5}"
OUT_CSV="${OUT_CSV:-bench-results.csv}"

# Single shared work dir so we don't keep recreating temp dirs.
WORK=$(mktemp -d -t bench-matrix)
trap 'rm -rf "$WORK"' EXIT

echo "mode,files,threads,edit,run,wall_seconds,frontend_jobs" >"$OUT_CSV"

total_cells=$(echo "$MODES $FILES $EDITS $THREADS" | awk '{print NF}')  # rough only
echo "# Bench matrix" >&2
echo "modes=[$MODES] files=[$FILES] edits=[$EDITS] threads=[$THREADS] runs=$RUNS" >&2
echo "csv → $OUT_CSV" >&2
echo "" >&2

for mode in $MODES; do
  for files in $FILES; do
    for edit in $EDITS; do
      # Threads only varies WMO; for other modes it's a no-op.
      thread_grid="$THREADS"
      if [[ "$mode" != "wmo" ]]; then thread_grid=$(echo "$THREADS" | awk '{print $1}'); fi
      for threads in $thread_grid; do
        echo "[run] mode=$mode files=$files edit=$edit threads=$threads runs=$RUNS" >&2
        "$BENCH" \
          --files "$files" --mode "$mode" --threads "$threads" --edit "$edit" \
          --runs "$RUNS" --work "$WORK" --no-header >>"$OUT_CSV"
      done
    done
  done
done

# Aggregate CSV → Markdown via python (statistics in stdlib).
python3 - "$OUT_CSV" <<'PY'
import csv, statistics, sys
from collections import defaultdict

path = sys.argv[1]
groups = defaultdict(lambda: {"wall": [], "jobs": []})

with open(path) as f:
    reader = csv.DictReader(f)
    for row in reader:
        key = (row["mode"], row["files"], row["threads"], row["edit"])
        groups[key]["wall"].append(float(row["wall_seconds"]))
        groups[key]["jobs"].append(int(row["frontend_jobs"]))

def pct(xs, p):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * (p / 100.0)
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)

print("| Mode | Files | Threads | Edit | p50 (s) | p95 (s) | Jobs (median) | N |")
print("|---|---:|---:|---|---:|---:|---:|---:|")
for key in sorted(groups, key=lambda k: (k[0], int(k[1]), int(k[2]), k[3])):
    mode, files, threads, edit = key
    walls = groups[key]["wall"]
    jobs = groups[key]["jobs"]
    p50 = statistics.median(walls)
    p95v = pct(walls, 95)
    jmed = int(statistics.median(jobs))
    th = "-" if mode != "wmo" else threads
    print(f"| {mode} | {files} | {th} | {edit} | {p50:.2f} | {p95v:.2f} | {jmed} | {len(walls)} |")
PY
