import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct ArchiveLoadingTests {
    private static func makeArchive(from object: URL, named name: String) throws -> URL {
        let archive = object.deletingLastPathComponent()
            .appendingPathComponent("lib\(name).a")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/libtool")
        process.arguments = ["-static", "-o", archive.path, object.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw JITLinkError.failed("libtool failed: \(process.terminationStatus)")
        }
        return archive
    }

    private static func makeDylib(source: String, named name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archiveload-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("\(name).swift")
        try source.write(to: src, atomically: true, encoding: .utf8)
        let dylib = dir.appendingPathComponent("lib\(name).dylib")
        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = args
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw JITLinkError.failed("\(args.first ?? "") failed: \(process.terminationStatus)")
            }
        }
        try run(["swiftc", "-emit-library", "-o", dylib.path, src.path])
        try run(["codesign", "-s", "-", dylib.path])
        return dylib
    }

    @Test func resolvesSymbolFromStaticArchiveInAgent() async throws {
        let compiler = try await Compiler()

        let libObject = try await compiler.compileObject(
            source: """
                @_cdecl("g3_lib_value")
                public func g3LibValue() -> Int32 { 7 }
                """,
            moduleName: "G3Lib"
        )
        let archive = try Self.makeArchive(from: libObject, named: "G3Lib")

        let mainObject = try await compiler.compileObject(
            source: """
                @_silgen_name("g3_lib_value") func g3LibValue() -> Int32

                @_cdecl("g3_main")
                public func g3Main() -> Int32 { g3LibValue() * 6 }
                """,
            moduleName: "G3Main"
        )

        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addArchive(path: archive.path)
        try session.addObject(path: mainObject.path)
        let result = try session.runOnMain(symbol: "g3_main")
        #expect(result == 42)
    }

    @Test func resolvesSymbolFromDylibInAgent() async throws {
        let compiler = try await Compiler()

        let dylib = try Self.makeDylib(
            source: """
                @_cdecl("g3b_lib_value")
                public func g3bLibValue() -> Int32 { 9 }
                """,
            named: "G3bLib"
        )

        let mainObject = try await compiler.compileObject(
            source: """
                @_silgen_name("g3b_lib_value") func g3bLibValue() -> Int32

                @_cdecl("g3b_main")
                public func g3bMain() -> Int32 { g3bLibValue() * 5 }
                """,
            moduleName: "G3bMain"
        )

        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addDylib(path: dylib.path)
        try session.addObject(path: mainObject.path)
        let result = try session.runOnMain(symbol: "g3b_main")
        #expect(result == 45)
    }
}
