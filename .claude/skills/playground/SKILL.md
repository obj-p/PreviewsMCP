---
name: playground
description: Create a temporary SwiftUI file and open a live preview for quick prototyping. Optionally describe what to build.
argument-hint: [description]
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, preview_start, preview_snapshot, preview_elements, preview_touch, preview_stop, preview_list, simulator_list
---

Create a standalone SwiftUI playground file and open a live preview.

## Arguments

- `$ARGUMENTS` — optional description of what to build (e.g., `a login form with email and password fields`). If omitted, creates a minimal "Hello, world!" view.

## Steps

1. **Create playground directory.** Run `mkdir -p ~/.previewsmcp/playground`. This directory persists across sessions and lives outside any project tree (important — placing files inside a project would trigger build system detection and fail).

2. **Generate playground file.** Create a new file at `~/.previewsmcp/playground/Playground_<short-id>.swift` where `<short-id>` is the first 8 characters of a UUID. Use the Write tool.

   - If `$ARGUMENTS` is provided, generate a SwiftUI view that matches the description. The file must contain `import SwiftUI`, a `View` struct, and a `#Preview` block.
   - If no arguments, write the default skeleton (use the short-id in the struct name, e.g., `Playground_a1b2c3d4View`):

   ```swift
   import SwiftUI

   struct Playground_<short-id>View: View {
       var body: some View {
           Text("Hello, world!")
       }
   }

   #Preview {
       Playground_<short-id>View()
   }
   ```

3. **Start preview.** Call `preview_start` with the absolute file path. Do NOT pass `projectPath` — standalone mode compiles the file directly without any build system. Default to macOS platform. If `preview_start` fails (e.g., compilation error from generated code), inspect the error, fix the file, and retry.

4. **Show snapshot.** Call `preview_snapshot` and display the result to the user.

5. **Guide iteration.** Tell the user:
   - They can ask for changes and you will edit the file — hot-reload updates the preview automatically
   - For iOS simulator rendering, they can ask you to restart with `platform: "ios-simulator"`
   - Playground files persist at `~/.previewsmcp/playground/` and can be deleted when no longer needed
