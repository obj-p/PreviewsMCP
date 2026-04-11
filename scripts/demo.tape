# PreviewsMCP CLI demo tape for vhs (https://github.com/charmbracelet/vhs).
# Regenerate with: scripts/record-demo.sh
# Requires: vhs (brew install vhs)

Output assets/demo.gif

Set FontSize 16
Set Width 1200
Set Height 600
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Set PlaybackSpeed 1.0
Set Padding 24

Hide
Type "rm -rf /tmp/pmcp-demo && mkdir -p /tmp/pmcp-demo && clear"
Enter
Show

Type "previewsmcp list examples/spm/Sources/ToDo/ToDoView.swift"
Sleep 500ms
Enter
Sleep 3s

Type "previewsmcp variants examples/spm/Sources/ToDo/ToDoView.swift \"
Enter
Type "  --variant light --variant dark \"
Enter
Type "  --format png -o /tmp/pmcp-demo/ 2>&1 | grep -v objc"
Sleep 500ms
Enter
Sleep 14s
