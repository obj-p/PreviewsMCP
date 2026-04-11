# PreviewsMCP iOS composite demo tape (terminal half).
#
# Run via scripts/record-demo-ios.sh — that orchestrator runs this
# tape plus `xcrun simctl io recordVideo` in parallel and hstacks the
# two streams into assets/demo.gif.
#
# Requires: vhs (brew install vhs).

Output "/tmp/pmcp-demo/terminal.mp4"

Set FontSize 18
Set Width 900
Set Height 720
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
Set PlaybackSpeed 1.0
Set Padding 24

Hide
Type "clear"
Enter
Show

Type "previewsmcp list examples/spm/Sources/ToDo/ToDoView.swift"
Sleep 400ms
Enter
Sleep 3s

Type "previewsmcp run examples/spm/Sources/ToDo/ToDoView.swift --platform ios --headless &"
Sleep 400ms
Enter
Sleep 12s

Type "# grow the summary card"
Enter
Sleep 500ms
Type "sed -i '' 's/.frame(height: 120)/.frame(height: 220)/' examples/spm/Sources/ToDo/ToDoView.swift"
Sleep 400ms
Enter
Sleep 5s

Type "# recolor on-brand"
Enter
Sleep 500ms
Type "sed -i '' 's/color: .blue/color: .pink/' examples/spm/Sources/ToDo/ToDoView.swift"
Sleep 400ms
Enter
Sleep 14s

Hide
Type "kill %1 2>/dev/null; wait 2>/dev/null"
Enter
Show
