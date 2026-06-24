# Repro: iOS shell crash on pre-iOS-26 simulators (#282)

The scene-hosting initializer the shell uses aborts on simulators older than
iOS 26 with:

```
NSInvalidArgumentException: -[_UISceneHostingControllerAdvancedConfiguration initWithClientIdentity:]: unrecognized selector
```

The crash site is `ios-host/shell/ShellMain.m` in `hostWithToken:`, which calls
`initWithClientIdentity:` through `performSelector` with no `respondsToSelector:`
guard. That private initializer exists on iOS 26 but not on earlier runtimes.

Verified on iOS 18.6: the class `_UISceneHostingControllerAdvancedConfiguration`
exists, but `instancesRespondToSelector:@selector(initWithClientIdentity:)` is
`NO`. On iOS 26.2 the selector is present. The issue was first reported on 18.3;
Apple no longer serves that point release for download, and any sub-26 runtime
shows the same selector gap.

## Why there is no `examples/` fixture

This is a runtime-compatibility bug in the shell, not a project-shape bug. The
trigger is the runtime, not the project, so it lives as a test plus this recipe.

## A nuance: the full session does not always reach the crash

On iOS 18.6 the production `IOSPreviewSession` does **not** crash. The shell
returns early in `clientIdentityForToken:` (FrontBoard hands back no client
identity on that runtime) before reaching the `initWithClientIdentity:` line, and
the agent renders to its own window regardless. So an end-to-end render check
passes even though the scene-hosting path is broken. The reporter's 18.3 runtime
returned a client identity, so its shell reached the crash line and aborted.

Because of this, the test below fires the **exact unguarded call** ShellMain
makes, rather than relying on the full session reaching it.

## Prerequisites

A sub-26 iOS simulator runtime installed. iOS 18.3 is no longer downloadable;
use a served point release such as 18.6:

```bash
xcodebuild -downloadPlatform iOS -buildVersion 18.6
xcrun simctl list runtimes | grep -i ios
```

## Reproduce via the test

`Tests/PreviewsJITLinkTests/IOSPreviewE2ETests.swift` has
`sceneHostingInitIsUnrecognizedSelectorOnPreIOS26`. It self-skips unless a sub-26
iPhone runtime is available, then spawns a probe inside that simulator that fires
ShellMain's `initWithClientIdentity:` call and asserts the `unrecognized selector`
abort.

```bash
swift test --filter sceneHostingInitIsUnrecognizedSelectorOnPreIOS26
```

- No pre-26 runtime installed → the test is skipped.
- Pre-26 runtime installed → the probe aborts with the unrecognized-selector
  signature and the test passes (reproduction confirmed).

## Reproduce manually

```objc
// Compile for the iphonesimulator and `xcrun simctl spawn <pre-26 udid> ./probe`.
dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
Class AdvCfg = NSClassFromString(@"_UISceneHostingControllerAdvancedConfiguration");
@try {
    [[AdvCfg alloc] performSelector:@selector(initWithClientIdentity:) withObject:[NSObject new]];
} @catch (NSException *e) {
    NSLog(@"%@", e.reason);  // -[... initWithClientIdentity:]: unrecognized selector ... on pre-26
}
```
