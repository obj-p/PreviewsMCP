#!/usr/bin/env bash
# Resumable driver: rebuild the research VM bundle from scratch and run the
# drive-xcode-preview capture (now with the previews log-stream collector).
# Each stage is guarded by the snapshot it produces, so re-running skips
# completed stages. Stops on first failure with a clear STAGE_FAIL marker.
#
# Stages mirror research/vm/PROGRESS.md "How to use today".
set -u

VMDIR="/Users/jasonprasad/Projects/PreviewsMCP/.worktrees/previews-research/research/vm"
PVM="$VMDIR/.build/release/previewsvm"
B="$HOME/.previews-research-vms/research.bundle"
IPSW="$HOME/.cache/previewsvm/ipsw/UniversalMac_26.3.1_25D2128_Restore.ipsw"
OUTDIR="/Users/jasonprasad/Projects/PreviewsMCP/.worktrees/previews-research/research/scripts/data/q1-dtrace-capture"
PW="previewsvm"

mkdir -p "$OUTDIR"
cd "$VMDIR" || { echo "STAGE_FAIL no vmdir"; exit 1; }

have_snap() { "$PVM" snapshot list "$B" 2>/dev/null | grep -qw "$1"; }
stage() { echo "=== STAGE $1 @ $(date -u +%H:%M:%SZ) ==="; }

# --- 1. install -----------------------------------------------------------
if [ ! -d "$B" ] || ! have_snap base; then
  stage "install"
  if [ ! -d "$B" ]; then
    "$PVM" install "$B" --ipsw "$IPSW" || { echo "STAGE_FAIL install"; exit 1; }
  fi
  "$PVM" snapshot take "$B" base || { echo "STAGE_FAIL snapshot base"; exit 1; }
  echo "STAGE_OK install+base"
else
  echo "STAGE_SKIP install (base snapshot exists)"
fi

# --- 2. Setup Assistant ---------------------------------------------------
if ! have_snap post-sa; then
  stage "setup-assistant"
  "$PVM" setup "$B" --preset explore-click-vnc --transport vnc \
      --retry 10 --restore-from base \
      || { echo "STAGE_FAIL setup-assistant"; exit 1; }
  "$PVM" snapshot take "$B" post-sa || { echo "STAGE_FAIL snapshot post-sa"; exit 1; }
  echo "STAGE_OK post-sa"
else
  echo "STAGE_SKIP setup-assistant (post-sa exists)"
fi

# --- 3. SSH provisioning --------------------------------------------------
if ! have_snap post-ssh; then
  stage "provision-ssh"
  "$PVM" setup "$B" --preset provision-ssh --transport vnc \
      --retry 2 --restore-from post-sa \
      || { echo "STAGE_FAIL provision-ssh"; exit 1; }
  "$PVM" snapshot take "$B" post-ssh || { echo "STAGE_FAIL snapshot post-ssh"; exit 1; }
  echo "STAGE_OK post-ssh"
else
  echo "STAGE_SKIP provision-ssh (post-ssh exists)"
fi

# --- 4. SIP off via recoveryOS -------------------------------------------
if ! have_snap post-sip; then
  stage "disable-sip"
  "$PVM" setup "$B" --preset disable-sip --transport vnc --recovery \
      --retry 3 --restore-from post-ssh \
      || { echo "STAGE_FAIL disable-sip"; exit 1; }
  "$PVM" snapshot take "$B" post-sip || { echo "STAGE_FAIL snapshot post-sip"; exit 1; }
  echo "STAGE_OK post-sip"
else
  echo "STAGE_SKIP disable-sip (post-sip exists)"
fi

# --- 5. AMFI off via SSH --------------------------------------------------
if ! have_snap post-amfi; then
  stage "amfi-off"
  "$PVM" boot "$B" --skip-ssh-wait > /tmp/provision-boot-amfi.log 2>&1 &
  for i in $(seq 1 60); do "$PVM" ssh "$B" true 2>/dev/null && break; sleep 5; done
  "$PVM" ssh "$B" "echo $PW | sudo -S nvram boot-args=amfi_get_out_of_my_way=1" \
      || { echo "STAGE_FAIL amfi nvram"; "$PVM" stop "$B"; exit 1; }
  "$PVM" ssh "$B" "echo $PW | sudo -S shutdown -h now" 2>/dev/null
  sleep 10
  "$PVM" stop "$B" 2>/dev/null
  "$PVM" snapshot take "$B" post-amfi || { echo "STAGE_FAIL snapshot post-amfi"; exit 1; }
  echo "STAGE_OK post-amfi"
else
  echo "STAGE_SKIP amfi-off (post-amfi exists)"
fi

# --- 6. Xcode tar-in ------------------------------------------------------
if ! have_snap post-xcode-sip-amfi; then
  stage "xcode-install"
  "$PVM" boot "$B" --skip-ssh-wait > /tmp/provision-boot-xcode.log 2>&1 &
  for i in $(seq 1 60); do "$PVM" ssh "$B" true 2>/dev/null && break; sleep 5; done
  VM_IP=$("$PVM" status "$B" | awk '/DHCP/{print $3}')
  tar -cf - -C /Applications Xcode-26.2.0.app | \
    ssh -i "$B/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        admin@"$VM_IP" 'mkdir -p /tmp/xcode-incoming && cd /tmp/xcode-incoming && tar -xf -' \
    || { echo "STAGE_FAIL xcode tar"; "$PVM" stop "$B"; exit 1; }
  "$PVM" ssh "$B" "echo $PW | sudo -S sh -c 'mv /tmp/xcode-incoming/Xcode-26.2.0.app /Applications/Xcode.app && xcode-select -s /Applications/Xcode.app'" \
      || { echo "STAGE_FAIL xcode mv"; "$PVM" stop "$B"; exit 1; }
  "$PVM" ssh "$B" "echo $PW | sudo -S xcodebuild -license accept" \
      || { echo "STAGE_FAIL xcode license"; "$PVM" stop "$B"; exit 1; }
  "$PVM" ssh "$B" "echo $PW | sudo -S shutdown -h now" 2>/dev/null
  sleep 10
  "$PVM" stop "$B" 2>/dev/null
  "$PVM" snapshot take "$B" post-xcode-sip-amfi || { echo "STAGE_FAIL snapshot post-xcode"; exit 1; }
  echo "STAGE_OK post-xcode-sip-amfi"
else
  echo "STAGE_SKIP xcode-install (post-xcode-sip-amfi exists)"
fi

# --- 7. drive-xcode-preview capture (with log-stream collector) -----------
stage "drive-xcode-preview"
"$PVM" setup "$B" --preset drive-xcode-preview --transport vnc \
    --retry 3 --restore-from post-xcode-ready \
    --output-dir "$OUTDIR" \
    || { echo "STAGE_FAIL drive-xcode-preview"; exit 1; }
echo "STAGE_OK capture"
echo "=== PIPELINE_COMPLETE @ $(date -u +%H:%M:%SZ) — artifacts in $OUTDIR ==="
