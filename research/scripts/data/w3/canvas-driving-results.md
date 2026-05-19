# Canvas-driving + capture attempt — results

**Status:** Drove Xcode end-to-end to a working preview render. Captured the
agent up, hot-reload triggered, lldb attached. **Final-mile blocked:** lldb's
symbol resolution against the attached XCPreviewAgent consistently reports
"No executable module" / "Unable to resolve breakpoint to any actual
locations," so the `__xojit_executor_write_mem` breakpoint never fires.
Eighteen iterations of the preset shipped before this dead-end.

## What works end-to-end

The `drive-xcode-preview` preset in `research/vm/Sources/previewsvm/SetupCommand.swift`
now drives the full SwiftUI hot-reload flow autonomously, every run:

1. Boot VM from `post-autologin-w3` snapshot.
2. Type admin password — unlocks the lock screen (auto-login fires but Aqua
   re-locks before SSH responds; the keystroke unlocks).
3. Start `caffeinate -dis &` on guest to prevent display sleep during 90s
   indexing wait.
4. Suppress Xcode's "Coding Intelligence" welcome modal via `defaults write`
   (best-effort; the dialog still appears but doesn't block subsequent
   keystrokes).
5. Rebuild the test package as a library target with a single
   `ContentView.swift` containing a `#Preview { ContentView() }` block. The
   prior `@main` + `main.swift` structure had a compile error that prevented
   preview activation.
6. Open `Package.swift` then `ContentView.swift` in Xcode (project context +
   focused source).
7. **Drive the preview canvas open via the Help menu's search field.** This
   is the load-bearing finding: Xcode 26 repurposed `Cmd+Option+Return` to
   open the new "Coding Intelligence" pane, not the preview canvas as in
   prior versions. `Cmd+Shift+Return`, `Cmd+Ctrl+Return`, and `Cmd+Opt+P`
   also do nothing useful. The reliable path is `Cmd+Shift+/` (Help menu
   search) → type "Canvas" → `Down` arrow → `Return`. This activates the
   `Editor → Canvas` menu item regardless of its current shortcut binding.
8. Wait for `XCPreviewAgent` to spawn (poll `pgrep -f XCPreviewAgent` over
   SSH). The preview canvas renders the actual SwiftUI `Hello`/`World` text
   in blue — verified in screenshot
   `16-03g-after-help-canvas-enter.png`.
9. Deploy the lldb capture script via hex+xxd.
10. `lldb -b -O 'target create --arch arm64e <agent>' -O 'process attach -p
    <pid>' -s capture-write-mem.lldb` against the spawned agent.
11. `sed`-edit `ContentView.swift` (`Hello` → `Howdy`).
12. Wait 30s.
13. Stop lldb, retrieve output.

## What blocks the final-mile capture

Output from steps 10-13 (verbatim, multiple runs):

```
(lldb) target create --arch arm64e /Applications/Xcode.app/.../XCPreviewAgent
Current executable set to '...XCPreviewAgent' (arm64e).
(lldb) process attach -p 954
Process 954 stopped
* thread #1, stop reason = signal SIGSTOP
Target 0: (No executable module.) stopped.
warning: No executable binary.
(lldb) br set --name __xojit_executor_write_mem
Breakpoint 1: no locations (pending).
WARNING:  Unable to resolve breakpoint to any actual locations.
[... same for the other three breakpoints ...]
(lldb) continue
Process 954 resuming
Process 954 stopped
* thread #1, stop reason = signal SIGKILL
```

Two compounding issues:

### Issue 1: lldb's target reports "No executable module" after attach

Despite `target create --arch arm64e <full-path-to-XCPreviewAgent>` being
successful (line 2 confirms "(arm64e)"), `process attach -p $PID` causes
lldb to report the target has no executable module. dyld's loaded-image
list isn't propagating to lldb's view of the process. This means breakpoint
resolution by symbol name has no modules to search in.

Variants tried, all fail the same way:
- `lldb $AGENT_BIN -p $PID -b -s script` (binary as positional arg)
- `lldb -p $PID -b -s script` (no binary)
- `lldb -b -O 'target create $AGENT_BIN' -O 'process attach -p $PID' -s script`
- `lldb -b -O 'target create --arch arm64e $AGENT_BIN' -O 'process attach -p $PID' -s script`

Possible reasons:
- AMFI restriction beyond `nvram boot-args="amfi_get_out_of_my_way=1"` —
  Apple may have a separate gate on debugging Xcode-bundled binaries.
- lldb 26.2's internal-SDK build has a regression in module-discovery for
  attached processes.
- The agent's loaded modules live entirely in `dyld_shared_cache_arm64e`
  and lldb's shared-cache path isn't being read correctly when attaching
  to a process (vs. spawning one).

### Issue 2: Agent receives SIGKILL shortly after lldb's `continue`

Once lldb resumes the agent, `previewsd` (or Xcode) sends SIGKILL within
seconds. Most likely cause: previewsd has an IPC-heartbeat timeout with
the agent; lldb's attach pause (~3-5s while breakpoints are being set)
exceeds it. Even if breakpoints did resolve, the captureable window is
very short.

Workaround attempts:
- Move breakpoints AFTER `continue` so the pause window is minimal — but
  then breakpoints can't resolve because the symbols are in modules lldb
  hasn't discovered.
- Use `process attach --continue` (auto-resume) — same symbol-resolution
  problem.

## Reusable infrastructure left in place

Despite the capture not landing, this iteration produced substantial
reusable infrastructure:

1. **`drive-xcode-preview` preset** in `SetupCommand.swift` (~300 LOC).
   The first end-to-end Xcode driver in the research VM. Auto-unlocks,
   handles modal dismissal, drives preview canvas open via Help menu
   search, polls for agent spawn, deploys capture script, triggers
   hot-reload via sed-edit. Works reliably (~6 minutes wall time).
2. **`.dualModifiedKey` step type** in `SetupAssistantSequence.swift`.
   Adds dual-modifier keystrokes (`Cmd+Opt+Return` etc) to the
   keyboard-scripting kit. Necessary for any Xcode UI driving.
3. **`.hostShell` step type** in same file. Runs arbitrary shell
   commands on the host (vs. typed-into-VM) and gates the next step on
   substring match of output. The mechanism that interleaves SSH-driven
   guest commands with VNC-driven keystrokes in one preset.
4. **`post-autologin-w3` snapshot** in `/tmp/verify.bundle/snapshots/`.
   Captures the admin-auto-login + `xcodebuild -runFirstLaunch` state.
   Every preset run restores from this; saves the ~10-minute first-launch
   setup.
5. **Xcode 26 canvas-shortcut finding**: `Cmd+Opt+Return` has been
   repurposed for Coding Intelligence; the canvas activates via Editor
   menu navigation only. Documented in the preset's comments.

## Per-edit address-list capture: where to go next

Three viable next attempts (all out of scope for this session):

1. **Use `DYLD_INSERT_LIBRARIES` to interpose `__xojit_executor_write_mem`**
   with a logging wrapper. Build a tiny `.dylib` that re-exports the symbol
   with `printf` + tail-call to the original. Inject it via XCPreviewAgent's
   launch environment. Bypasses lldb entirely; doesn't depend on symbol
   discovery in lldb's attach-time module list. Most likely to work.
2. **Spawn the agent UNDER lldb** rather than attaching. `lldb` spawning
   a process gets full module visibility from the start. Trick: previewsd
   spawns the agent, not the user — we'd need to launch the agent
   manually with synthesized env vars (the path the seed prompt
   suggested originally).
3. **Custom dtrace probe with `csops` workaround**. Apple's `dtrace` has
   a check that fails for our case; understanding the specific check
   (it's in `dt_proc_create` per Apple's xnu source) would let us
   bypass.

Approach (1) is the cleanest. The agent's env includes
`DYLD_INSERT_LIBRARIES=PreviewsInjection.framework` already — we could
add a second dylib that re-exports the four `__xojit_executor_*` symbols.
At symbol-resolution time, our interposer wins, logs args, calls the
original.

## State files

- `/tmp/verify.bundle/snapshots/post-autologin-w3` — VM snapshot
  reusable for any future capture attempt.
- `/tmp/w3-drive-output/` — most recent run's screenshots + the
  empty-of-hits lldb output.
- `research/scripts/data/w3/16-03g-after-help-canvas-enter.png` — proof
  that the canvas + agent + preview render works end-to-end.
- `research/scripts/data/w3/19-05-lldb-running.png` — proof that lldb
  attached during the hot-reload window.
- `research/vm/Sources/previewsvm/SetupCommand.swift` — the
  `drive-xcode-preview` preset, ready to re-run with a different capture
  mechanism plugged in (interposer dylib at step 9-10).
