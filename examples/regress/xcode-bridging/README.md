# Objective-C Bridging Header

`BridgingView` calls `BridgedGreeting.greeting()`, an Objective-C class made
visible only through the target's `SWIFT_OBJC_BRIDGING_HEADER` build setting.
There is no module or import statement to discover: reproducing the compile
requires reading the bridging header setting from the Xcode target and passing
`-import-objc-header`, plus compiling and linking the `.m` implementation.

The generated project is committed (regenerate with `xcodegen generate` after
editing `project.yml`) so the X02 guard test runs without XcodeGen installed.
