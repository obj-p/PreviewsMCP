#!/usr/bin/env bash
# One-time prep: run Xcode's first-launch headlessly so the GUI component
# modal never appears, then snapshot. Restores post-xcode-sip-amfi, runs
# `xcodebuild -runFirstLaunch` over SSH, shuts down, snapshots
# post-xcode-ready. The capture stage then restores post-xcode-ready.
set -u
VMDIR="/Users/jasonprasad/Projects/PreviewsMCP/.worktrees/previews-research/research/vm"
PVM="$VMDIR/.build/release/previewsvm"
B="$HOME/.previews-research-vms/research.bundle"
PW="previewsvm"
cd "$VMDIR" || { echo "STAGE_FAIL no vmdir"; exit 1; }

echo "=== restore post-xcode-sip-amfi @ $(date -u +%H:%M:%SZ) ==="
"$PVM" snapshot restore "$B" post-xcode-sip-amfi || { echo "STAGE_FAIL restore"; exit 1; }

echo "=== boot ==="
"$PVM" boot "$B" --skip-ssh-wait > /tmp/prep-boot.log 2>&1 &
for i in $(seq 1 60); do "$PVM" ssh "$B" true 2>/dev/null && break; sleep 5; done

echo "=== xcodebuild -runFirstLaunch (installs components headlessly) ==="
"$PVM" ssh "$B" "echo $PW | sudo -S xcodebuild -runFirstLaunch" \
    || { echo "STAGE_FAIL runFirstLaunch"; "$PVM" stop "$B"; exit 1; }
echo "=== verify: xcodebuild -checkFirstLaunchStatus ==="
"$PVM" ssh "$B" "xcodebuild -checkFirstLaunchStatus; echo RC=$?" 2>&1 | tail -3

echo "=== shutdown + snapshot post-xcode-ready ==="
"$PVM" ssh "$B" "echo $PW | sudo -S shutdown -h now" 2>/dev/null
sleep 10
"$PVM" stop "$B" 2>/dev/null
"$PVM" snapshot take "$B" post-xcode-ready || { echo "STAGE_FAIL snapshot"; exit 1; }
echo "=== PREP_COMPLETE @ $(date -u +%H:%M:%SZ) — post-xcode-ready created ==="
