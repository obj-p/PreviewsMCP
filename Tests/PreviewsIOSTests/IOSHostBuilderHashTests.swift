import CryptoKit
import Foundation
import Testing

@testable import PreviewsIOS

/// Pin the byte-shape of the iOS host app artifacts (source, plist,
/// icon) used by `IOSHostBuilder.sourceHash`. The hash is the cache
/// invariant: an identical hash before and after the host-app
/// extraction refactor (#7) proves the plugin-generated constants
/// produce a runtime String identical to the previous hand-written
/// triple-quoted blob.
///
/// The expected hash was captured from the pre-refactor codebase. If
/// it changes intentionally (someone edits the host app or icon),
/// update the constant; the change should land in the same PR as the
/// edit so future readers can trace the value.
@Suite("IOSHostBuilder source hash")
struct IOSHostBuilderHashTests {

    @Test("source/plist/icon hash is stable across refactors")
    func hashIsStable() {
        var hasher = SHA256()
        hasher.update(data: Data(IOSHostAppSource.code.utf8))
        hasher.update(data: Data(IOSHostAppSource.infoPlist.utf8))
        hasher.update(data: IOSAppIconData.bytes)
        let digest = hasher.finalize()
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        // Pre-refactor value. If the iOS host-app source, the Info.plist,
        // or the AppIcon.png bytes change, this value MUST be updated
        // (and the change should land in the same PR as the edit).
        // Updated 2026-05-06 for #160: HostApp.swift gained body-kind probe
        // dlsym + reloadAck/init handshake reporting.
        // Updated 2026-06-15 for iOS JIT: HostApp.swift gained the
        // PREVIEWSMCP_IOS_JIT --jit-port branch that starts the in-app ORC
        // executor, and the dylib-arg guard no longer fails in JIT mode.
        // Updated 2026-06-15 for iOS JIT render: JIT mode installs a placeholder
        // root view controller at launch so UIKit's end-of-launch assertion
        // doesn't abort before the first render over EPC.
        // Updated 2026-06-15 for dylib Phase B: iOS is JIT-only now, so HostApp.swift
        // dropped all dylib loading (loadPreview/showError/applyLiterals, the
        // --dylib/--setup-dylib args, and the reload/init/literals handlers).
        // Updated 2026-06-16 for iOS JIT mandatory: the --jit-port branch and the
        // startJITExecutor/connectLoopback helpers are no longer behind #if.
        let expected = "5b900b18a768b57caf614f60ef988436716efa2ecaa12043d5485c8c08b6d03d"
        #expect(hash == expected, "host-app artifact hash drifted (was \(expected), now \(hash))")
    }
}
