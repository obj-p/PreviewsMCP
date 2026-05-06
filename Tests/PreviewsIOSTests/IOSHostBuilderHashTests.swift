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
        let expected = "ba6a5667d62c06384e8e79f5924e753986bb91e4f47cc0962b861583c9677af6"
        #expect(hash == expected, "host-app artifact hash drifted (was \(expected), now \(hash))")
    }
}
