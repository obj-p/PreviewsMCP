# SwiftPM Compiler Settings

This package intentionally makes a recursive source walk and a generic `swiftc`
command differ from SwiftPM's real target command. `SettingsFixture` retains
the compound reproduction, while three smaller targets isolate compiler
settings, plugin output, and source membership plus the C module.

- Swift 5 language mode through a Swift 5.9 manifest;
- conditional defines and strict-concurrency flags;
- an upcoming language feature;
- explicit `sources` and `exclude` membership;
- a Clang target with public headers;
- a build-tool plugin that emits `GeneratedFixtureStamp.swift`;
- processed JSON and localized resources;
- a UIKit protocol-extension implementation that is sensitive to actor
  isolation defaults.

`Excluded/DoNotCompile.swift` contains a valid `#error`. SwiftPM excludes it, so
the package builds. If Tier 2 recursively compiles every `.swift` file, the
diagnostic makes the membership bug unambiguous.

Run PreviewsMCP with `--build-system spm` against
`Sources/SettingsFixture/SettingsPreview.swift`. The effective Tier 2 command
should preserve SwiftPM's compile-affecting flags, include the plugin output and
Clang module, and omit the excluded file.

The current reproduction reaches the intended boundary: SwiftPM's project build
succeeds, then Tier 2 includes `Excluded/DoNotCompile.swift`, omits the
build-tool output and target-specific settings, and cannot import `FixtureC`.

Run the isolated targets separately before the compound target:

- `Sources/CompilerSettings/CompilerSettingsPreview.swift`
- `Sources/GeneratedPlugin/GeneratedPluginPreview.swift`
- `Sources/MembershipAndC/MembershipAndCPreview.swift`
