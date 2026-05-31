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

    @Test func linksCObject() throws {
        let object = try FixtureSupport.compile("answer.c")
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [object.path],
            symbol: "answer"
        )
        #expect(result == 42)
    }

    @Test func linksSwiftObject() throws {
        let object = try FixtureSupport.compile("swift_answer.swift")
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [object.path],
            symbol: "swift_answer"
        )
        #expect(result == 42)
    }

    @Test func resolvesProcessSymbolThroughExecutor() throws {
        let object = try FixtureSupport.compile("external.c", extraFlags: ["-fno-builtin"])
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [object.path],
            symbol: "compute"
        )
        #expect(result == 42)
    }

    @Test func throwsOnMissingSymbol() throws {
        let object = try FixtureSupport.compile("answer.c")
        #expect(throws: JITLinkError.self) {
            let _: Int32 = try PreviewsJITLink.linkAndCall(
                objectPaths: [object.path],
                symbol: "does_not_exist"
            )
        }
    }

    @Test func runsObjectInitializer() throws {
        let object = try FixtureSupport.compile("ctor.c")
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [object.path],
            symbol: "ctor_answer"
        )
        #expect(result == 42)
    }
}
