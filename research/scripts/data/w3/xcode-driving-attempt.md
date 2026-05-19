# Xcode-driving attempt (W3 address-list capture)

**Date:** 2026-05-19. **Status:** Blocked at "trigger preview canvas without
GUI keystrokes." Documented honestly so a future attempt doesn't redo the
same dead ends.

**Goal:** Run [`capture-write-mem.d`](capture-write-mem.d) against
`XCPreviewAgent` during a real Xcode hot-reload to enumerate the specific
PWT/GOT slot addresses written per edit. Closes the address-list portion
of W3 deliverable #2 (mechanism level was closed at commit `94c86a1`).

## What worked

1. **Auto-login via `/etc/kcpassword` + `autoLoginUser` defaults write.**
   After this lands and the VM reboots, `stat -f '%Su' /dev/console`
   resolves to `admin` (was `root`/loginwindow). `w` shows `admin` on
   the console TTY. The admin user has a real Aqua session.

2. **AppleScript over SSH for direct Application scripting.**
   `osascript -e 'tell application "Xcode" to activate'` works.
   `osascript -e 'tell application "Xcode" to open (POSIX file "/path/to/file.swift")'`
   works — returns `"source document main.swift"`. Direct AppleScript
   verbs against an application (no System Events) traverse the
   loginwindow-driven Aqua session cleanly.

3. **`xcodebuild -runFirstLaunch`** clears the "Install additional
   required components" first-run modal that otherwise blocks Xcode's
   AppleScript responsiveness. Run this once per fresh Xcode install
   before any AppleScript driving. After it succeeds, Xcode is
   AppleScript-responsive (`version`, `frontmost`) and can open files.

4. **Test SwiftUI source file** at `~/HelloPreview/Sources/HelloPreview/main.swift`
   plus a `Package.swift` declaring an executable target. Opens in
   Xcode via `open -a Xcode Package.swift`. SwiftBuild, SKAgent, and a
   stack of XPC helpers spawn correctly.

## What didn't work

1. **System Events / accessibility scripting over SSH** —
   `osascript -e 'tell application "System Events" to ...'` returns
   `AppleEvent timed out (-1712)`. The SSH session doesn't inherit TCC
   accessibility permission, so any keystroke / mouse-event
   delivery via osascript times out. Unblocking this would require
   either:
   - Granting `/usr/bin/osascript` Accessibility permission in
     `/Library/Application Support/com.apple.TCC/TCC.db` (system-auth
     change; SIP off makes this technically possible but it's a
     separate authorization).
   - Or driving Xcode via the host-side `previewsvm` keystroke
     scripter (`PreviewsVMKit.KeyboardScripter`, which uses
     NSEvent.postEvent). The latter needs the VM booted with
     `--with-display` and a new custom preset wired into
     `previewsvm setup` — multi-hour Swift work.

2. **Xcode `windows` / `source documents` AppleScript queries** —
   time out even after a source document is successfully opened. The
   `frontmost` and `open` verbs work; the collection queries don't.
   Probably an Xcode-26.2-specific AppleScript regression; the
   workaround would be to act instead of query.

3. **`xcrun --find xcpreviewagent` and `xcrun --find previewsd`** —
   neither is in xcrun's discovery path. `previewsd` lives in the
   dyld shared cache (no on-disk binary; `find` returns nothing).
   No CLI helper exists to start the preview pipeline; canvas
   activation is GUI-mediated.

4. **Preview rendering without an open canvas.** Even after a file
   with `#Preview { ... }` is open in Xcode, no `XCPreviewAgent`
   process spawns. The preview canvas (Editor → Canvas, default
   keystroke `Cmd-Option-Return`) is the trigger; without it, Xcode
   doesn't initiate the preview pipeline. There's no AppleScript verb
   for "show canvas" and no CLI for it.

## Where this blocks

The remaining work to capture the address list:

1. Either grant `osascript` Accessibility / Automation permission via
   a direct TCC.db write (SIP-off VM permits, but it's a system-auth
   change).
2. Or write a custom `previewsvm` preset that:
   - Boots the VM with `--with-display`.
   - Uses `PreviewsVMKit.KeyboardScripter.type(...)` to deliver
     keystrokes via NSEvent.postEvent.
   - Sends `Cmd-Option-Return` after the source file opens to toggle
     the canvas.
   - Waits for `XCPreviewAgent` to spawn (poll `ps` over SSH).
   - Starts `capture-write-mem.d` on the agent PID.
   - Sends keystrokes to edit a literal in the body.
   - Sends `Cmd-S` to save → triggers hot-reload.
   - Stops dtrace, captures output.

The second path is more reusable (a `drive-xcode` preset becomes
part of the research-VM kit) but is multi-hour code work.

## Why this doesn't change the design

The W3 mechanism-level finding (Apple uses LLVM `SimpleRemoteEPC`;
patch via `___xojit_executor_write_mem` after host-side ORC decides
addresses) is the architectural input the design doc needs. The
address-list capture refines the patch-point set table in
[`prompts/jit-executor-design.md`](../../../prompts/jit-executor-design.md) §2
(currently lists all kinds; would refine with frequencies) and could
surface a kind we didn't predict (unlikely — the W2 POC exercised
all of them).

This is genuinely Phase-4 production-hardening work as the design
doc itself classifies it. Not blocking Phase 1.

## State left in the VM

- `/etc/kcpassword` (12 bytes, root:wheel, 0600) — enables admin auto-login.
- `/Library/Preferences/com.apple.loginwindow.plist`: `autoLoginUser=admin`.
- `~/HelloPreview/` — minimal SwiftUI test package.
- Xcode 26.2 first-launch components installed (`xcodebuild -runFirstLaunch` ran).
- Snapshot `post-xcode-sip-amfi` is the original base; no new snapshot taken
  with the auto-login + first-launch state.

The next attempt should take a fresh snapshot named `post-autologin-w3` (or
similar) from this state before starting, so the auto-login + first-launch
components don't need to be re-applied every session.
