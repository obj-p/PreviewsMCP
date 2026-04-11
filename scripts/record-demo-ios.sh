#!/usr/bin/env bash
# Regenerate assets/demo.gif — the side-by-side iOS hot-reload demo
# shown at the top of the README.
#
# Pipeline:
#   1. warm the iOS host app + dylib caches with a throwaway snapshot
#   2. start `xcrun simctl io recordVideo` against the booted simulator
#      in the background (captures the phone screen as it updates)
#   3. run `vhs scripts/demo-ios.tape`, which drives the terminal:
#        previewsmcp list … → previewsmcp run … --platform ios & →
#        two sed edits that trigger literal/structural hot reload
#   4. stop the simulator recording, composite the two streams
#      side-by-side with ffmpeg (`hstack` + `tpad` so both final frames
#      are held visible — simctl recordVideo is variable-framerate and
#      only samples on screen changes, so the naive composite would cut
#      off at the exact transition), render to gif with a generated
#      palette
#
# The script is idempotent: it reverts the example source file on exit
# (trap) so git stays clean even if anything fails partway through.
#
# One-time setup:
#   brew install vhs ffmpeg
#
# Then:
#   scripts/record-demo-ios.sh
#
# Tweaking the demo: edit scripts/demo-ios.tape. Timings (the `Sleep`
# directives after each sed) need to stay long enough for the simulator
# to render the post-reload frame — simctl's sparse sampling means
# cutting close is risky. 10s after the final edit is a safe minimum.

set -euo pipefail

cd "$(dirname "$0")/.."

for tool in vhs ffmpeg xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool not found on PATH" >&2
    exit 1
  fi
done

# Pick the previewsmcp binary to use.
if [[ -x .build/release/previewsmcp ]]; then
  bin_dir="$PWD/.build/release"
elif [[ -x .build/debug/previewsmcp ]]; then
  bin_dir="$PWD/.build/debug"
else
  echo "Building previewsmcp (release)..."
  swift build -c release
  bin_dir="$PWD/.build/release"
fi
export PATH="$bin_dir:$PATH"

mkdir -p /tmp/pmcp-demo assets

# Ensure a simulator is booted. If none, boot the first available iPhone.
if ! xcrun simctl list devices booted 2>/dev/null | grep -q '(Booted)'; then
  udid=$(xcrun simctl list devices available \
    | grep -Eo '\(([0-9A-F-]{36})\)' \
    | head -1 | tr -d '()')
  if [[ -z "${udid:-}" ]]; then
    echo "error: no available iOS simulator devices" >&2
    exit 1
  fi
  echo "Booting simulator $udid..."
  xcrun simctl boot "$udid"
  sleep 3
fi

# Always leave the example file pristine on exit, even if we crash.
EXAMPLE_FILE="examples/spm/Sources/ToDo/ToDoView.swift"
trap 'git checkout -- "$EXAMPLE_FILE" 2>/dev/null || true; \
      [[ -n "${SIM_PID:-}" ]] && kill -INT "$SIM_PID" 2>/dev/null || true; \
      pkill -f "previewsmcp run $EXAMPLE_FILE" 2>/dev/null || true' EXIT

# Warm the iOS host app + dylib caches so the recorded `run` is as fast
# as possible, then uninstall so the recording starts clean and the
# re-install picks up any updated AppIcon.png.
echo "Warming iOS caches..."
previewsmcp snapshot "$EXAMPLE_FILE" --platform ios -o /tmp/pmcp-demo/warmup.png >/dev/null 2>&1
xcrun simctl terminate booted com.obj-p.previewsmcp.host 2>/dev/null || true
xcrun simctl uninstall booted com.obj-p.previewsmcp.host 2>/dev/null || true

# Drive the simulator to a clean home screen. `simctl terminate` +
# `simctl uninstall` alone don't return to home — iOS preserves a
# snapshot of the last foreground app. Kicking SpringBoard forces a
# fresh home screen (the warning about the service identifier is
# benign — the command still works).
xcrun simctl spawn booted launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
sleep 10

# Start simulator video capture in the background.
rm -f /tmp/pmcp-demo/sim.mp4 /tmp/pmcp-demo/terminal.mp4
echo "Starting simulator recording..."
xcrun simctl io booted recordVideo --codec=h264 /tmp/pmcp-demo/sim.mp4 &
SIM_PID=$!
sleep 1

# Run the tape. vhs drives the shell and records the terminal to mp4.
echo "Running vhs tape..."
vhs scripts/demo-ios.tape

# Stop simulator recording cleanly.
echo "Stopping simulator recording..."
kill -INT "$SIM_PID" 2>/dev/null || true
wait "$SIM_PID" 2>/dev/null || true
SIM_PID=""

# Trim sim to match the terminal's duration (plus a small tail buffer).
# Two tricks:
#  - Trimming discards the 1s lead-in where simctl was recording but
#    vhs hadn't started typing yet.
#  - Trimming the tail cuts simctl's post-SIGINT activity — simctl
#    tends to capture a ghost frame at a much later timestamp when
#    the app is torn down, which would otherwise stretch the composite.
# `-ss`/`-to` don't cooperate with VFR sources, so we trim inside the
# filtergraph via the `trim` filter (order matters: `fps` before `trim`
# on VFR input).
term_dur=$(ffprobe -v error -show_entries stream=duration -of csv=p=0 \
  /tmp/pmcp-demo/terminal.mp4)
sim_end=$(awk -v t="$term_dur" 'BEGIN {printf "%.3f", t + 1.5}')

# Composite: trim the sim lead-in and tail, force both inputs to a
# constant 15fps, scale both to 960 tall, tpad 3s of the last frame so
# the post-reload state is held visible, then hstack. CFR + tpad are
# both required because `simctl io recordVideo` is variable-framerate
# and only samples on screen changes — without CFR the simulator half
# drifts out of sync with the terminal, and without tpad the transition
# frame gets cut at the right edge. Height 960 keeps the iPhone screen
# large enough to read text in the gif.
echo "Compositing..."
ffmpeg -y \
  -i /tmp/pmcp-demo/terminal.mp4 \
  -i /tmp/pmcp-demo/sim.mp4 \
  -filter_complex "\
    [0:v]fps=15,tpad=stop_mode=clone:stop_duration=3,scale=-2:960,setsar=1[t];\
    [1:v]fps=15,trim=start=1:end=${sim_end},setpts=PTS-STARTPTS,tpad=stop_mode=clone:stop_duration=3,scale=-2:960,setsar=1[s];\
    [t][s]hstack=inputs=2" \
  -c:v libx264 -pix_fmt yuv420p -r 15 \
  /tmp/pmcp-demo/composite.mp4 >/dev/null 2>&1

# Render the gif with a generated palette for quality. Keep the gif at
# the composite's framerate (15) so playback feels smooth.
echo "Rendering gif..."
ffmpeg -y -i /tmp/pmcp-demo/composite.mp4 \
  -vf "fps=15,scale=1600:-2:flags=lanczos,palettegen=stats_mode=diff" \
  /tmp/pmcp-demo/palette.png >/dev/null 2>&1
ffmpeg -y -i /tmp/pmcp-demo/composite.mp4 -i /tmp/pmcp-demo/palette.png \
  -lavfi "fps=15,scale=1600:-2:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" \
  assets/demo.gif >/dev/null 2>&1

echo "Wrote assets/demo.gif"
ls -la assets/demo.gif
