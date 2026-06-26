---
name: previewsmcp-ios
description: View and interact with a running SwiftUI preview in the iOS Simulator through the PreviewsMCP server. Use whenever the user wants to see, open, tap, drag, or hot-reload an iOS SwiftUI preview, or asks to open the interactive preview/viewer for an iOS file.
---

# iOS interactive preview (PreviewsMCP)

PreviewsMCP renders a SwiftUI preview in a real iOS Simulator and hosts a
per-session viewer over a loopback web server. The viewer streams the live
preview and forwards taps and drags back to the Simulator. Your job is to start
the preview and open that viewer so the user sees it without leaving the host.

## Steps

1. **Pick a simulator.** Call `simulator_list` and choose a booted iOS device,
   or one the user names. Keep its `udid`.

2. **Start the preview.** Call `preview_start` with the SwiftUI source file:
   `{ filePath: "<abs path>", platform: "ios", deviceUDID: "<udid>" }`. The
   result text ends with a line of the form:

   `Interactive viewer: http://127.0.0.1:<port>/ — open it in the in-app browser.`

   The port is also in `structuredContent.appServerPort`. Capture the URL.

3. **Open the viewer.** Open the captured `http://127.0.0.1:<port>/` URL in the
   host's in-app browser so the user sees the live, interactive preview. Probe
   the tools available in this session and use whichever opens a URL:
   - Codex: open it in the in-app browser (`@Browser`).
   - A host preview/browser tool that takes `{ url }`: hand off the URL.
   Do not assume a specific tool exists. If none does, present the URL
   prominently and tell the user to open it in their browser.

4. **Interact.** Drive the preview with `preview_touch` (tap and swipe) and read
   the screen with `preview_snapshot`. Edits to the source file hot-reload
   automatically; the viewer updates live. Use `preview_switch` to change the
   active preview and `preview_stop` to end the session.

## Notes

- The viewer is a real browser page on loopback, not a sandboxed panel. Opening
  it in an in-app browser or an external browser both work; a sandboxed MCP-app
  iframe cannot reach loopback and will not.
- One viewer per session. Re-running `preview_start` for the same file reuses
  the session and its port.
