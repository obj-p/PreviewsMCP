import Foundation
import PreviewsJITLink
import Testing

struct PreviewsJITLinkTests {
    @Test func mainDylibName() throws {
        #expect(try PreviewsJITLink.mainDylibName() == "main")
    }

    @Test func targetTripleIsArm64Apple() {
        #expect(PreviewsJITLink.targetTriple().hasPrefix("arm64-apple"))
    }

    @Test func linkAndCallAnswerReturns42() throws {
        let object = try FixtureSupport.compile("answer.c")
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPath: object.path,
            symbol: "answer"
        )
        #expect(result == 42)
    }
}
