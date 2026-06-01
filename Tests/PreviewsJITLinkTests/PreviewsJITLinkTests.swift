import Foundation
import PreviewsJITLink
import Testing

struct PreviewsJITLinkTests {
    @Test func linksCObject() throws {
        let object = try FixtureSupport.compile("answer.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "answer")
        #expect(result == 42)
    }

    @Test func linksSwiftObject() throws {
        let object = try FixtureSupport.compile("swift_answer.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "swift_answer")
        #expect(result == 42)
    }

    @Test func resolvesProcessSymbolThroughExecutor() throws {
        let object = try FixtureSupport.compile("external.c", extraFlags: ["-fno-builtin"])
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "compute")
        #expect(result == 42)
    }

    @Test func throwsOnMissingSymbol() throws {
        let object = try FixtureSupport.compile("answer.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        #expect(throws: JITLinkError.self) {
            let _: Int32 = try session.call(symbol: "does_not_exist")
        }
    }

    @Test func runsObjectInitializer() throws {
        let object = try FixtureSupport.compile("ctor.c")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "ctor_answer")
        #expect(result == 42)
    }

    @Test func dispatchesThroughWitnessTable() throws {
        let object = try FixtureSupport.compile("witness.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "witness_value")
        #expect(result == 7)
    }

    @Test func resolvesConformanceThroughRuntimeRegistry() throws {
        let object = try FixtureSupport.compile("dynamic_cast.swift")
        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "dynamic_cast_value")
        #expect(result == 9)
    }
}
