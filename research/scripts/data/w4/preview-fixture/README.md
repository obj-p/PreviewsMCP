# preview-fixture — minimal SwiftUI app for the W4 thunk-argv capture

One `@main` app + one `ContentView` with a `#Preview` and a literal to edit
(`Text("edit me 0")`). The `.xcodeproj` is gitignored; regenerate it with
`xcodegen generate`.

## Capture Apple's thunk-compile argv (one command + one edit)

1. `cd preview-fixture && xcodegen generate && xed PreviewFixture.xcodeproj`
2. Open `ContentView.swift`, show the canvas (Editor ▸ Canvas), wait for the
   first render.
3. In a terminal: `../capture-thunk-compile.sh 60`
4. Back in Xcode, change the `0` in `"edit me 0"` to `1` and save. Repeat once
   or twice.
5. The captured `swift-frontend` argv lands in `../w4-thunk-argv.txt`.
