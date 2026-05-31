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

    @Test(.disabled("SP0c: JIT-linked Swift conformance crashes swift_conformsToProtocol. Root-caused: not relocs (Delta32 edges are correct intra-image), not the slab, not LLVM version. The runtime accesses the __swift5_proto section at a wrong base (0x300000000 region, unmapped) vs JITLink's link address (0x124e...). Section-address registration mismatch in ExecutorNativePlatform's Swift handling. Fix is the design's SwiftEntrySectionPlugin: register conformances with the correct final addresses."))
    func dispatchesThroughWitnessTable() throws {
        let object = try FixtureSupport.compile("witness.swift")
        let result: Int32 = try PreviewsJITLink.linkAndCall(
            objectPaths: [object.path],
            symbol: "witness_value"
        )
        #expect(result == 7)
    }
}
