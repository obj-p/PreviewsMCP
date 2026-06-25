#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: merge-bar.sh <bundle>}"

WORK="${WORK:-$HOME/mq-work}"
ADMIN_PASS="${ADMIN_PASS:-vzvz}"
CANDIDATE_REF="${CANDIDATE_REF:-mq-candidate}"
BASE_REF="${BASE_REF:-mq-base}"
JIT_CACHE="${JIT_CACHE:-$HOME/jit-cache}"

log() { printf '\n=== %s ===\n' "$*"; }
rsudo() { printf '%s\n' "$ADMIN_PASS" | sudo -S -p '' "$@"; }

eval "$(/opt/homebrew/bin/brew shellenv)"

log "swift toolchain"
xcrun swift --version

log "preparing worktree from $BUNDLE ($CANDIDATE_REF rebased onto $BASE_REF)"
rm -rf "$WORK"
git clone --quiet "$BUNDLE" "$WORK"
cd "$WORK"
git checkout --quiet "$CANDIDATE_REF"
git -c user.name=merge-queue -c user.email=merge-queue@local rebase "origin/$BASE_REF"

ln -sfn "$JIT_CACHE" "$WORK/third_party"

run_lint() {
    log "lint: brew bundle"
    brew bundle --file=Brewfile
    log "lint: swift-format"
    swift-format lint --strict --recursive Sources/ Tests/ examples/
    log "lint: swiftlint"
    swiftlint lint --quiet Sources/ Tests/
    log "lint: clang-format"
    find Sources -type f \( -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' -o -name '*.m' -o -name '*.mm' \) -print0 \
        | xargs -0 clang-format --dry-run --Werror
}

run_build_and_test() {
    export PREVIEWSMCP_SOCKET_DIR=/tmp/previewsmcp-mq-build
    export NSUnbufferedIO=YES
    log "build: swift build"
    swift build
    log "build: example spm"
    swift build --package-path examples/spm
    log "test: PreviewsCoreTests"
    swift test --filter "PreviewsCoreTests"
    log "test: CLIIntegrationTests"
    swift test --filter "CLIIntegrationTests" --skip "snapshotIOS" --skip "iosCLIWorkflow"
    log "test: MCPIntegrationTests"
    swift test --filter "MCPIntegrationTests" --skip "IOSMCPTests"
}

run_jit() {
    export NSUnbufferedIO=YES
    log "test: PreviewsJITLinkTests (--no-parallel)"
    swift test --filter "PreviewsJITLinkTests" --no-parallel
}

run_ios() {
    export PREVIEWSMCP_SOCKET_DIR=/tmp/previewsmcp-mq-ios
    export NSUnbufferedIO=YES
    log "ios: warm CoreSimulator"
    xcrun simctl list devices available >/dev/null
    log "test: PreviewsIOSTests"
    swift test --filter "PreviewsIOSTests"
    log "test: snapshotIOS"
    swift test --filter "snapshotIOS"
    log "ios: kill stale daemon"
    .build/debug/previewsmcp kill-daemon --timeout 3 || true
    log "test: iosCLIWorkflow"
    swift test --filter "iosCLIWorkflow"
    log "ios: reset CoreSimulator"
    xcrun simctl shutdown all 2>&1 || true
    killall -9 "Simulator" "com.apple.CoreSimulator.CoreSimulatorService" 2>&1 || true
    sleep 3
    xcrun simctl list devices >/dev/null 2>&1 || true
    log "test: IOSMCPTests"
    swift test --filter "IOSMCPTests"
}

run_lint
run_build_and_test
run_jit
run_ios

log "merge bar PASSED for $CANDIDATE_REF"
