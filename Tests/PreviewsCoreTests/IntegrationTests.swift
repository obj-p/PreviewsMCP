import Testing
import Foundation
@testable import PreviewsCore

@Suite("Integration Tests")
struct IntegrationTests {

    static let testViewSource = """
    import SwiftUI

    struct TestView: View {
        @State private var count = 0
        var body: some View {
            VStack {
                Text("Count: \\(count)")
                Button("Increment") { count += 1 }
            }
        }
    }

    #Preview {
        TestView()
    }
    """

    // MARK: - Parse → Generate → Compile

    @Test("Full pipeline: parse, generate bridge, compile to dylib")
    func fullPipeline() async throws {
        // 1. Parse
        let previews = PreviewParser.parse(source: Self.testViewSource)
        #expect(previews.count == 1)
        #expect(previews[0].closureBody.contains("TestView()"))

        // 2. Generate bridge (now returns tuple with literals)
        let (combined, literals) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testViewSource,
            closureBody: previews[0].closureBody
        )
        #expect(combined.contains("@_cdecl"))
        #expect(combined.contains("createPreviewView"))
        #expect(combined.contains("DesignTimeStore"))
        #expect(!literals.isEmpty, "Should have replaced some literals")

        // 3. Compile
        let compiler = try await Compiler()
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "IntegrationTest_\(Int.random(in: 0...999999))"
        )

        // Verify dylib exists and is non-empty
        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "Dylib should be non-empty")

        // 4. Load the dylib
        let loader = try DylibLoader(path: result.dylibPath.path)

        // 5. Verify the entry point symbol exists
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")

        // 6. Verify DesignTimeStore setter symbols exist
        typealias SetString = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
        let _: SetString = try loader.symbol(name: "designTimeSetString")
        typealias SetInt = @convention(c) (UnsafePointer<CChar>, Int) -> Void
        let _: SetInt = try loader.symbol(name: "designTimeSetInteger")
    }

    // MARK: - PreviewSession

    @Test("PreviewSession compiles a source file end-to-end")
    func previewSession() async throws {
        // Write test source to a temp file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("TestView.swift")
        try Self.testViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            compiler: compiler
        )

        let compileResult = try await session.compile()
        #expect(FileManager.default.fileExists(atPath: compileResult.dylibPath.path))

        // Load and verify entry point
        let loader = try DylibLoader(path: compileResult.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")
    }

    // MARK: - Recompilation produces fresh dylib

    @Test("Multiple compilations produce distinct dylibs that dlopen loads separately")
    func recompilationProducesFreshDylib() async throws {
        let compiler = try await Compiler()

        let (source1, _) = BridgeGenerator.generateCombinedSource(
            originalSource: """
            import SwiftUI
            struct V1: View {
                var body: some View { Text("Version 1") }
            }
            #Preview { V1() }
            """,
            closureBody: "V1()"
        )

        let (source2, _) = BridgeGenerator.generateCombinedSource(
            originalSource: """
            import SwiftUI
            struct V2: View {
                var body: some View { Text("Version 2") }
            }
            #Preview { V2() }
            """,
            closureBody: "V2()"
        )

        let moduleName = "RecompileTest_\(Int.random(in: 0...999999))"

        let result1 = try await compiler.compileCombined(source: source1, moduleName: moduleName)
        let result2 = try await compiler.compileCombined(source: source2, moduleName: moduleName)

        // Paths should be different (unique counter suffix)
        #expect(result1.dylibPath != result2.dylibPath, "Each compilation should produce a unique dylib path")

        // Both should be loadable
        let loader1 = try DylibLoader(path: result1.dylibPath.path)
        let loader2 = try DylibLoader(path: result2.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader1.symbol(name: "createPreviewView")
        let _: CreateFunc = try loader2.symbol(name: "createPreviewView")
    }

    // MARK: - Error cases

    @Test("PreviewSession throws for invalid preview index")
    func invalidPreviewIndex() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("TestView.swift")
        try Self.testViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 5, // only 1 preview exists
            compiler: compiler
        )

        await #expect(throws: PreviewSessionError.self) {
            _ = try await session.compile()
        }
    }

    @Test("Compiler reports errors for invalid Swift source")
    func compilerError() async throws {
        let compiler = try await Compiler()
        let badSource = "this is not valid swift {"

        await #expect(throws: CompilationError.self) {
            _ = try await compiler.compileCombined(
                source: badSource,
                moduleName: "BadSource_\(Int.random(in: 0...999999))"
            )
        }
    }

    // MARK: - File Watcher

    @Test("FileWatcher detects file modification")
    func fileWatcherDetectsChange() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("watched.swift")
        try "initial content".write(to: file, atomically: true, encoding: .utf8)

        let changed = Mutex(false)
        let watcher = try FileWatcher(path: file.path, interval: 0.1) {
            changed.withLock { $0 = true }
        }
        defer { watcher.stop() }

        // Wait a moment, then modify the file
        try await Task.sleep(for: .milliseconds(200))
        try "modified content".write(to: file, atomically: true, encoding: .utf8)

        // Wait for the watcher to detect the change
        try await Task.sleep(for: .milliseconds(500))

        let didChange = changed.withLock { $0 }
        #expect(didChange, "FileWatcher should detect the file modification")
    }
}

/// Simple mutex for thread-safe access in tests.
final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) {
        self.value = value
    }

    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
