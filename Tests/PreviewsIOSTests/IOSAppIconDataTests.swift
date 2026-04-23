import Foundation
import Testing

@testable import PreviewsIOS

@Suite("IOSAppIconData")
struct IOSAppIconDataTests {

    /// Catches a corrupted regen paste: accessing `bytes` forces the lazy
    /// static to decode, so a truncated/mangled base64 literal fatal-errors
    /// here instead of surfacing later in the iOS host-app build pipeline.
    @Test("Embedded base64 decodes to a valid PNG")
    func decodesToValidPNG() {
        let bytes = IOSAppIconData.bytes
        #expect(!bytes.isEmpty)
        // PNG signature: 89 50 4E 47 0D 0A 1A 0A
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        #expect(Array(bytes.prefix(signature.count)) == signature)
    }
}
