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
            objectPaths: [object.path],
            symbol: "answer"
        )
        #expect(result == 42)
    }

    @Test func resolvesExternalSymbolFromHost() throws {
        let object = try FixtureSupport.compile("external.c", extraFlags: ["-fno-builtin"])
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [object.path],
            symbol: "compute"
        )
        #expect(result == 42)
    }

    @Test func resolvesSymbolAcrossObjects() throws {
        let caller = try FixtureSupport.compile("caller.c")
        let helper = try FixtureSupport.compile("helper.c")
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [caller.path, helper.path],
            symbol: "composed"
        )
        #expect(result == 42)
    }
}
