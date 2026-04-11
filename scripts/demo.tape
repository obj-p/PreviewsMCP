# PreviewsMCP CLI demo tape for vhs (https://github.com/charmbracelet/vhs).
# Regenerate with: scripts/record-demo.sh
# Requires: vhs, chafa (brew install vhs chafa)

Output assets/demo.gif

Set FontSize 16
Set Width 1200
Set Height 720
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Set PlaybackSpeed 1.0
Set Padding 24

Hide
Type "clear"
Enter
Show

Type "previewsmcp list examples/spm/Sources/ToDo/ToDoView.swift"
Sleep 500ms
Enter
Sleep 2s

Type "previewsmcp snapshot examples/spm/Sources/ToDo/ToDoView.swift -o /tmp/demo-light.png"
Sleep 500ms
Enter
Sleep 6s

Type "previewsmcp snapshot examples/spm/Sources/ToDo/ToDoView.swift --color-scheme dark -o /tmp/demo-dark.png"
Sleep 500ms
Enter
Sleep 6s

Type "chafa --size=70x24 --symbols=block /tmp/demo-light.png /tmp/demo-dark.png"
Sleep 500ms
Enter
Sleep 5s
