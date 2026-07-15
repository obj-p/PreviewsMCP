# Xcode Generated and Runtime Resources

Generate the project with `xcodegen generate`, then run PreviewsMCP on
`Sources/ResourcePreview.swift` with `--build-system xcode`.

The target enables Swift asset-symbol generation and contains a named color, a
localized string catalog, a plist resource, and a Core Data model with class
code generation. A healthy preview compile includes Xcode's generated Swift
sources, while runtime lookup uses the built framework bundle containing the
compiled resources.

The visible rows make partial success obvious: generated `Color.fixtureAccent`
must compile, and the preview must report both the plist and Core Data model as
loaded at runtime.

The current baseline is deliberately partial: the generated color compiles and
renders, but the localized key, plist, and Core Data model miss at runtime.
That isolates bundle lookup/staging from generated-source compilation.
