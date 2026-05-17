import Foundation
import Testing

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

    @Test("BridgeGenerator produces UIKit code for iOS simulator")
    func bridgeGeneratorIOS() {
        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testViewSource,
            closureBody: "TestView()",
            platform: .iOS
        )
        #expect(combined.contains("import UIKit"))
        #expect(combined.contains("UIHostingController"))
        #expect(!combined.contains("NSHostingView"))
        #expect(!combined.contains("import AppKit"))
        #expect(combined.contains("@_cdecl"))
    }

    @Test("Compile preview dylib for iOS simulator")
    func compileForIOSSimulator() async throws {
        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testViewSource,
            closureBody: "TestView()",
            platform: .iOS
        )
        let compiler = try await Compiler(platform: .iOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "IOSTest_\(Int.random(in: 0...999999))"
        )

        // Can't dlopen an iOS simulator dylib on macOS, but verify it exists and is non-empty
        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)
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
            previewIndex: 5,  // only 1 preview exists
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
        let watcher = try FileWatcher(path: file.path) {
            changed.withLock { $0 = true }
        }
        defer { watcher.stop() }

        // Give FSEvents time to install its watch before mutating.
        try await Task.sleep(for: .milliseconds(100))
        try "modified content".write(to: file, atomically: true, encoding: .utf8)

        // Wait for the watcher to detect the change (FSEvents latency ~50ms).
        try await Task.sleep(for: .milliseconds(200))

        let didChange = changed.withLock { $0 }
        #expect(didChange, "FileWatcher should detect the file modification")
    }

    /// Atomic-rename is how NSDocument, Xcode, JetBrains, and default-config
    /// vim save. The original inode is unlinked and replaced — a kqueue/
    /// inode-based watcher would go silent here; FSEvents reports the event
    /// at path granularity.
    @Test("FileWatcher detects atomic-rename save")
    func fileWatcherAtomicRename() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("watched.swift")
        try "initial".write(to: file, atomically: false, encoding: .utf8)

        let changed = Mutex(false)
        let watcher = try FileWatcher(path: file.path) {
            changed.withLock { $0 = true }
        }
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(100))

        let initialInode =
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber]
            as? UInt64

        // Explicit write-temp + rename, not `atomically: true` (which would
        // hide whether the rename path is what we actually exercise).
        let tmp = tempDir.appendingPathComponent("watched.swift.tmp")
        try "modified".write(to: tmp, atomically: false, encoding: .utf8)
        let renamed = rename(tmp.path, file.path)
        #expect(renamed == 0, "rename(2) should succeed")

        let finalInode =
            try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber]
            as? UInt64
        #expect(
            initialInode != nil && finalInode != nil && initialInode != finalInode,
            "rename(2) should have replaced the file's inode (so this exercises the inode-vanish hole, not an in-place write)"
        )

        try await Task.sleep(for: .milliseconds(200))

        #expect(
            changed.withLock { $0 },
            "FileWatcher should detect an atomic-rename save"
        )
    }

    /// FSEvents coalesces successive writes inside its latency window into a
    /// single delivery. The contract we care about is "at least one
    /// callback" — zero would be a regression.
    @Test("FileWatcher fires at least once for back-to-back saves")
    func fileWatcherBackToBackSaves() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("watched.swift")
        try "initial".write(to: file, atomically: false, encoding: .utf8)

        let callCount = Mutex(0)
        let watcher = try FileWatcher(path: file.path) {
            callCount.withLock { $0 += 1 }
        }
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(100))

        // Two writes inside the ~50ms latency window. FSEvents may coalesce
        // them into a single callback — that is expected and fine.
        try "write 1".write(to: file, atomically: false, encoding: .utf8)
        try "write 2".write(to: file, atomically: false, encoding: .utf8)

        try await Task.sleep(for: .milliseconds(200))

        let count = callCount.withLock { $0 }
        #expect(count >= 1, "Back-to-back saves should produce at least one callback, got \(count)")
    }

    /// Some editors (and some Foundation paths) delete the file and create
    /// a new one on every save. A path-based watcher must survive this; an
    /// inode-bound one would not.
    @Test("FileWatcher survives delete-and-recreate save pattern")
    func fileWatcherDeleteRecreate() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = tempDir.appendingPathComponent("watched.swift")
        try "initial".write(to: file, atomically: false, encoding: .utf8)

        let callCount = Mutex(0)
        let watcher = try FileWatcher(path: file.path) {
            callCount.withLock { $0 += 1 }
        }
        defer { watcher.stop() }

        try await Task.sleep(for: .milliseconds(100))

        // Two delete-and-recreate cycles, spaced well past the latency
        // window so each cycle gets its own delivery rather than being
        // coalesced into the first. Per-cycle assertion catches the
        // regression where only the initial cycle fires.
        for i in 1...2 {
            let beforeCycle = callCount.withLock { $0 }
            try FileManager.default.removeItem(at: file)
            try "save \(i)".write(to: file, atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(300))
            let afterCycle = callCount.withLock { $0 }
            #expect(
                afterCycle > beforeCycle,
                "Cycle \(i): watcher should have fired after delete+recreate (before=\(beforeCycle), after=\(afterCycle))"
            )
        }
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
