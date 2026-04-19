#!/usr/bin/env bash
# Regenerate assets/demo.gif — the side-by-side iOS hot-reload demo
# shown at the top of the README.
#
# Pipeline:
#   1. warm the iOS host app + dylib caches with a throwaway snapshot
#   2. capture simulator screenshots at each state (home, preview,
#      after height edit, after color edit)
#   3. run `vhs scripts/demo-ios.tape` to record the terminal half
#   4. build a fake sim video from the stills with frame-accurate
#      timing that matches the terminal events, then hstack + gif
#
# The fake-sim approach guarantees perfect sync — the old live-
# recording method had inherent drift because simctl recordVideo is
# VFR and can't be frame-aligned with the terminal tape.
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
# Tweaking the demo: edit scripts/demo-ios.tape and adjust the
# SIM_*_AT / SIM_*_DUR timing constants below to match.

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
      previewsmcp stop --all 2>/dev/null || true; \
      previewsmcp kill-daemon 2>/dev/null || true' EXIT

# -------------------------------------------------------------------
# Phase 1: capture simulator screenshots at each demo state
# -------------------------------------------------------------------

echo "Warming iOS caches..."
previewsmcp snapshot "$EXAMPLE_FILE" --platform ios -o /tmp/pmcp-demo/warmup.png >/dev/null 2>&1
previewsmcp stop --all 2>/dev/null || true
xcrun simctl terminate booted com.obj-p.previewsmcp.host 2>/dev/null || true
xcrun simctl uninstall booted com.obj-p.previewsmcp.host 2>/dev/null || true

# Return to home screen for the "before" screenshot.
xcrun simctl spawn booted launchctl kickstart -k system/com.apple.SpringBoard 2>/dev/null || true
sleep 10

echo "Capturing home screen..."
xcrun simctl io booted screenshot /tmp/pmcp-demo/state_home.png

echo "Starting preview session..."
previewsmcp run "$EXAMPLE_FILE" --platform ios --detach >/dev/null 2>&1
sleep 4
echo "Capturing original preview..."
xcrun simctl io booted screenshot /tmp/pmcp-demo/state_original.png

echo "Applying height edit..."
sed -i '' 's/.frame(height: 120)/.frame(height: 220)/' "$EXAMPLE_FILE"
sleep 4
echo "Capturing height change..."
xcrun simctl io booted screenshot /tmp/pmcp-demo/state_height.png

echo "Applying color edit..."
sed -i '' 's/color: .blue/color: .pink/' "$EXAMPLE_FILE"
sleep 4
echo "Capturing color change..."
xcrun simctl io booted screenshot /tmp/pmcp-demo/state_color.png

# Clean up the session — the example file gets reverted by the trap.
previewsmcp stop --all 2>/dev/null || true
previewsmcp kill-daemon 2>/dev/null || true

# -------------------------------------------------------------------
# Phase 2: record the terminal tape
# -------------------------------------------------------------------

# Revert so the tape's sed commands actually produce changes.
git checkout -- "$EXAMPLE_FILE"

rm -f /tmp/pmcp-demo/terminal.mp4
echo "Running vhs tape..."
vhs scripts/demo-ios.tape

# -------------------------------------------------------------------
# Phase 3: build a fake sim video from stills and composite
# -------------------------------------------------------------------

# Timing constants — seconds into the terminal video when each sim
# state should appear. Derived from the tape's typing speed + sleeps.
# Tweak these if you change the tape.
#
# Terminal timeline (approximate):
#   0s      typing `list`
#   5.3s    typing `run --detach`
#   8.3s    run enters → daemon starts
#  10.0s    app appears on sim (daemon + install takes ~2s)
#  18.3s    typing height comment
#  23.0s    height sed executes
#  24.0s    sim shows height change (~1s reload)
#  31.0s    typing color comment
#  35.0s    color sed executes
#  36.0s    sim shows color change (~1s reload)
#  43.0s    end
SIM_HOME_DUR=10      # home screen for first 10s
SIM_ORIGINAL_DUR=14  # original preview from 10s to 24s
SIM_HEIGHT_DUR=12    # taller card from 24s to 36s
SIM_COLOR_DUR=10     # pink card from 36s to end (+ tpad holds it)

echo "Building sim video from stills..."
ffmpeg -y \
  -loop 1 -t "$SIM_HOME_DUR"     -i /tmp/pmcp-demo/state_home.png \
  -loop 1 -t "$SIM_ORIGINAL_DUR" -i /tmp/pmcp-demo/state_original.png \
  -loop 1 -t "$SIM_HEIGHT_DUR"   -i /tmp/pmcp-demo/state_height.png \
  -loop 1 -t "$SIM_COLOR_DUR"    -i /tmp/pmcp-demo/state_color.png \
  -filter_complex "\
    [0:v]fps=15,scale=-2:960,setsar=1[a];\
    [1:v]fps=15,scale=-2:960,setsar=1[b];\
    [2:v]fps=15,scale=-2:960,setsar=1[c];\
    [3:v]fps=15,scale=-2:960,setsar=1[d];\
    [a][b][c][d]concat=n=4:v=1:a=0[sim]" \
  -map "[sim]" -c:v libx264 -pix_fmt yuv420p -r 15 \
  /tmp/pmcp-demo/sim_fake.mp4 >/dev/null 2>&1

echo "Compositing..."
ffmpeg -y \
  -i /tmp/pmcp-demo/terminal.mp4 \
  -i /tmp/pmcp-demo/sim_fake.mp4 \
  -filter_complex "\
    [0:v]fps=15,tpad=stop_mode=clone:stop_duration=3,scale=-2:960,setsar=1[t];\
    [1:v]fps=15,tpad=stop_mode=clone:stop_duration=3,scale=-2:960,setsar=1[s];\
    [t][s]hstack=inputs=2" \
  -c:v libx264 -pix_fmt yuv420p -r 15 \
  /tmp/pmcp-demo/composite.mp4 >/dev/null 2>&1

echo "Rendering gif..."
ffmpeg -y -i /tmp/pmcp-demo/composite.mp4 \
  -vf "fps=15,scale=1600:-2:flags=lanczos,palettegen=stats_mode=diff" \
  /tmp/pmcp-demo/palette.png >/dev/null 2>&1
ffmpeg -y -i /tmp/pmcp-demo/composite.mp4 -i /tmp/pmcp-demo/palette.png \
  -lavfi "fps=15,scale=1600:-2:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5" \
  assets/demo.gif >/dev/null 2>&1

echo "Wrote assets/demo.gif"
ls -la assets/demo.gif
