import PreviewsJITLink
import Testing

struct PreviewsJITLinkTests {
    @Test func targetTripleIsArm64Apple() {
        let triple = PreviewsJITLink.targetTriple()
        #expect(triple.hasPrefix("arm64-apple"))
    }
}
