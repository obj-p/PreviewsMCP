# Generated Xcode Project State

These fixtures distinguish three failures that otherwise look like a generic
Xcode build error.

## Missing output

`missing-output` contains common generated-project inputs (`project.yml`,
`Cartfile`, `Package.swift`, and `BUILD.bazel`) but intentionally has no
`.xcodeproj`. Auto-detection should report that generated output is absent and
show the marker candidates it considered. Running `xcodegen generate` is the
control case; remove `MissingOutput.xcodeproj` to restore the reproduction.

## Stale output

`stale-output/StaleOutput.xcodeproj` was generated when the target contained
only `LegacyView.swift`. The checked-in `project.yml` now includes
`NewPreview.swift`, while the checked-in project still does not. This represents
a manifest edited without regenerating the project. A source-ownership check
should diagnose stale output rather than compiling some other target.

## Multi-target ownership

`multi-target/MultiTarget.xcodeproj` has one `Combined` scheme that builds both
Alpha and Beta. `BetaPreview.swift` imports a type owned only by Beta. Selecting
the first build-settings record is insufficient; PreviewsMCP must select the
record whose target owns the requested source.
