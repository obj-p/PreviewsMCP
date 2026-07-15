# Macro Targets

Two boundaries around Swift macros:

1. `Sources/MacroClient/MacroClientPreview.swift` uses `#fixtureStamp()`, a
   custom macro declared in `FixtureMacros` and implemented in the
   `FixtureMacrosPlugin` macro target. Compiling the client requires building
   the plugin executable for the host and passing it via
   `-load-plugin-executable`.
2. `Sources/ToolchainMacroClient/ToolchainMacroPreview.swift` uses only the
   toolchain-provided `@Observable` macro, which resolves through the default
   compiler plugin path with no package dependency.

This is the one fixture with an external SwiftPM dependency: macro
implementations require `swift-syntax`. The committed `Package.resolved` pins
the exact revision, and the first build fetches and compiles it.
