# Terminal half of the iOS composite demo. Run via scripts/record-demo-ios.sh.
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
Sleep 14s

Type "# hot reload: change the navigation title"
Enter
Sleep 800ms
Type "sed -i '' 's/My Items/Focus Mode/' examples/spm/Sources/ToDo/ToDoView.swift"
Sleep 400ms
Enter
Sleep 10s

Hide
Type "kill %1 2>/dev/null; wait 2>/dev/null"
Enter
Show
