import Foundation
@testable import PreviewsCore
import Testing

@Suite("SPMCommandCapture")
struct SPMCommandCaptureTests {
    /// The real llbuild manifest shape: `C.`-prefixed compile nodes with
    /// single-line JSON `inputs:`/`args:` arrays, plus non-compile nodes and
    /// a prefix-colliding sibling target that anchoring must not confuse.
    private static let manifest = """
    client:
      name: basic
    tools: {}
    commands:
      "P.plugin-output":
        tool: shell
        inputs: ["/pkg/Plugins/Gen/"]
        outputs: ["/pkg/.build/plugins/outputs/Gen/Generated.swift"]
        args: ["/usr/bin/sandbox-exec","-p","(version 1)","tool","/pkg/.build/plugins/outputs/Gen/Generated.swift"]
      "C.ToDo-arm64-apple-macosx26.0-debug.module":
        tool: shell
        inputs: ["/pkg/Sources/ToDo/View.swift","/pkg/Sources/ToDo/Item.swift","/pkg/.build/arm64-apple-macosx/debug/ToDo.build/DerivedSources/resource_bundle_accessor.swift","/pkg/.build/arm64-apple-macosx/debug/swift-version.txt","<ToDo-resources>","/pkg/.build/arm64-apple-macosx/debug/FixtureC.build/FixtureC.c.o"]
        outputs: ["/pkg/.build/arm64-apple-macosx/debug/ToDo.build/View.swift.o"]
        description: "Compiling Swift Module 'ToDo' (3 sources)"
        args: ["/toolchain/usr/bin/swiftc","-module-name","ToDo","-emit-module","-DSWIFT_PACKAGE","-package-name","spm"]
      "C.ToDoExtras-arm64-apple-macosx26.0-debug.module":
        tool: shell
        inputs: ["/pkg/Sources/ToDoExtras/Extra.swift"]
        outputs: ["/pkg/.build/arm64-apple-macosx/debug/ToDoExtras.build/Extra.swift.o"]
        description: "Compiling Swift Module 'ToDoExtras' (1 sources)"
        args: ["/toolchain/usr/bin/swiftc","-module-name","ToDoExtras","-emit-module","-DEXTRAS"]
    """

    private func writeManifest() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).yaml")
        try Self.manifest.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("captures the target's args without the executable and its Swift inputs")
    func capturesArgsAndInputs() throws {
        let url = try writeManifest()
        defer { try? FileManager.default.removeItem(at: url) }

        let captured = try SPMCommandCapture.capture(manifestAt: url, forTarget: "ToDo")
        #expect(captured.arguments.first == "-module-name")
        #expect(captured.arguments.contains("-package-name"))
        #expect(!captured.arguments.contains { $0.hasSuffix("swiftc") })
        #expect(
            captured.swiftInputs.map(\.lastPathComponent)
                == ["View.swift", "Item.swift", "resource_bundle_accessor.swift"]
        )
    }

    @Test("prefix-colliding target names do not cross-match")
    func prefixCollision() throws {
        let url = try writeManifest()
        defer { try? FileManager.default.removeItem(at: url) }

        let extras = try SPMCommandCapture.capture(manifestAt: url, forTarget: "ToDoExtras")
        #expect(extras.arguments.contains("-DEXTRAS"))
        #expect(extras.swiftInputs.map(\.lastPathComponent) == ["Extra.swift"])
    }

    @Test("a target with no compile node throws")
    func unknownTargetThrows() throws {
        let url = try writeManifest()
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: BuildSystemError.self) {
            try SPMCommandCapture.capture(manifestAt: url, forTarget: "Nope")
        }
    }

    @Test("a missing manifest throws")
    func missingManifestThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-missing-\(UUID().uuidString).yaml")
        #expect(throws: BuildSystemError.self) {
            try SPMCommandCapture.capture(manifestAt: missing, forTarget: "ToDo")
        }
    }

    @Test("prefers the real compile node (-c) over a wrapper node for the same module")
    func prefersCompileNodeOverWrapper() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).yaml")
        try """
        commands:
          "C.ToDo-arm64-apple-macosx26.0-debug.module-wrapper":
            tool: shell
            args: ["/toolchain/usr/bin/swiftc","-module-name","ToDo","-emit-module"]
          "C.ToDo-arm64-apple-macosx26.0-debug.module":
            tool: shell
            args: ["/toolchain/usr/bin/swiftc","-module-name","ToDo","-c","-package-name","spm"]
            inputs: ["/pkg/Sources/ToDo/View.swift"]
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let captured = try SPMCommandCapture.capture(manifestAt: url, forTarget: "ToDo")
        #expect(captured.arguments.contains("-package-name"))
        #expect(captured.swiftInputs.map(\.lastPathComponent) == ["View.swift"])
    }

    @Test("inputs after args within a node are still captured")
    func inputsAfterArgs() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).yaml")
        try """
        commands:
          "C.ToDo-arm64-apple-macosx26.0-debug.module":
            tool: shell
            args: ["/toolchain/usr/bin/swiftc","-module-name","ToDo","-c"]
            inputs: ["/pkg/Sources/ToDo/View.swift"]
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let captured = try SPMCommandCapture.capture(manifestAt: url, forTarget: "ToDo")
        #expect(captured.swiftInputs.map(\.lastPathComponent) == ["View.swift"])
    }

    @Test("a matching module name in a non-compile node is ignored")
    func nonCompileNodeIgnored() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).yaml")
        try """
        commands:
          "Shell.something":
            tool: shell
            args: ["/bin/echo","-module-name","ToDo"]
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: BuildSystemError.self) {
            try SPMCommandCapture.capture(manifestAt: url, forTarget: "ToDo")
        }
    }
}

@Suite("CompileCommandNormalizer")
struct CompileCommandNormalizerTests {
    @Test("strips build bookkeeping and keeps semantic flags")
    func stripsBookkeeping() {
        let captured = [
            "-module-name", "SettingsFixture",
            "-emit-dependencies",
            "-emit-module",
            "-emit-module-path", "/pkg/.build/debug/Modules/SettingsFixture.swiftmodule",
            "-output-file-map", "/pkg/.build/debug/output-file-map.json",
            "-parse-as-library",
            "-incremental",
            "-c",
            "@/pkg/.build/debug/SettingsFixture.build/sources",
            "-I", "/pkg/.build/debug/Modules",
            "-target", "arm64-apple-macosx14.0",
            "-enable-batch-mode",
            "-serialize-diagnostics",
            "-index-store-path", "/pkg/.build/debug/index/store",
            "-Onone",
            "-enable-testing",
            "-g",
            "-Xcc", "-fPIC", "-Xcc", "-g",
            "-j16",
            "-DSWIFT_PACKAGE", "-DDEBUG", "-DSETTINGS_FIXTURE",
            "-Xcc", "-fmodule-map-file=/pkg/.build/debug/FixtureC.build/module.modulemap",
            "-Xcc", "-I", "-Xcc", "/pkg/Sources/FixtureC/include",
            "-module-cache-path", "/pkg/.build/debug/ModuleCache",
            "-parseable-output",
            "-emit-objc-header",
            "-emit-objc-header-path", "/pkg/.build/debug/include/SettingsFixture-Swift.h",
            "-swift-version", "5",
            "-enable-upcoming-feature", "ExistentialAny",
            "-strict-concurrency=targeted",
            "-plugin-path", "/toolchain/lib/swift/host/plugins/testing",
            "-sdk", "/sdk/MacOSX26.2.sdk",
            "-package-name", "spm",
        ]
        let normalized = CompileCommandNormalizer.normalize(captured)
        let joined = normalized.joined(separator: " ")

        #expect(joined.contains("-DSETTINGS_FIXTURE"))
        #expect(joined.contains("-swift-version 5"))
        #expect(joined.contains("-enable-upcoming-feature ExistentialAny"))
        #expect(joined.contains("-strict-concurrency=targeted"))
        #expect(joined.contains("-package-name spm"))
        #expect(joined.contains("-I /pkg/.build/debug/Modules"))
        #expect(joined.contains("-Xcc -fmodule-map-file="))
        #expect(joined.contains("-Xcc -I -Xcc /pkg/Sources/FixtureC/include"))
        #expect(joined.contains("-plugin-path"))
        #expect(joined.contains("-enable-testing"))

        #expect(joined.contains("-target arm64-apple-macosx14.0"))
        #expect(joined.contains("-sdk /sdk/MacOSX26.2.sdk"))

        #expect(!joined.contains("-module-name"))
        #expect(!joined.contains("-emit-module"))
        #expect(!joined.contains("output-file-map"))
        #expect(!joined.contains("-j16"))
        #expect(!normalized.contains("-g"))
        #expect(joined.contains("-Xcc -fPIC"))
        #expect(!joined.contains("-Xcc -g"))
        #expect(!joined.contains("-Xcc -Xcc"))
        #expect(!joined.contains("-Xcc -j"))
        #expect(!joined.contains("-Xcc -package-name"))
        #expect(!joined.contains("ModuleCache"))
        #expect(!joined.contains("index/store"))
        #expect(!joined.contains("SettingsFixture-Swift.h"))
    }

    @Test("keeps -Xfrontend-wrapped macro plugin loads and unknown flags")
    func keepsPluginLoadsAndUnknownFlags() {
        let captured = [
            "-Xfrontend", "-load-plugin-executable",
            "-Xfrontend", "/pkg/.build/debug/MacroImpl-tool#MacroImpl",
            "-Xfrontend", "-serialize-debugging-options",
            "-some-future-flag", "value",
        ]
        let normalized = CompileCommandNormalizer.normalize(captured)
        let joined = normalized.joined(separator: " ")

        #expect(
            joined.contains(
                "-Xfrontend -load-plugin-executable -Xfrontend /pkg/.build/debug/MacroImpl-tool#MacroImpl"
            )
        )
        #expect(!joined.contains("-serialize-debugging-options"))
        #expect(joined.contains("-some-future-flag value"))
    }

    @Test("drops bare source file tokens")
    func dropsBareSources() {
        let normalized = CompileCommandNormalizer.normalize(
            ["/pkg/Sources/ToDo/View.swift", "-DDEBUG"]
        )
        #expect(normalized == ["-DDEBUG"])
    }
}

@Suite("Preview module names")
struct PreviewModuleNameTests {
    @Test("non-identifier characters in file stems are sanitized")
    func sanitizesStems() {
        #expect(PreviewSession.sanitizedIdentifier("Unicode–Preview") == "Unicode_Preview")
        #expect(PreviewSession.sanitizedIdentifier("With Space") == "With_Space")
        #expect(PreviewSession.sanitizedIdentifier("Plain_09") == "Plain_09")

        let name = PreviewSession.moduleName(
            for: URL(fileURLWithPath: "/tmp/Space Dir/Unicode–Preview.swift")
        )
        #expect(name.hasPrefix("Preview_Unicode_Preview_"))
        #expect(name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
    }
}

@Suite("XcodeCommandCapture")
struct XcodeCommandCaptureTests {
    private func makeFileList(_ sources: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xc-\(UUID().uuidString).SwiftFileList")
        try sources.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("parses the driver line and expands the SwiftFileList")
    func parsesDriverLine() throws {
        let fileList = try makeFileList(["/proj/Sources/App.swift", "/proj/Sources/View.swift"])
        defer { try? FileManager.default.removeItem(at: fileList) }
        let log = """
        Build description path: /dd/XCBuildData/x.xcbuilddata
        SwiftDriver\\ Compilation BridgingApp normal arm64 (in target 'BridgingApp' from project 'BridgingApp')
            builtin-SwiftDriver -- /toolchain/usr/bin/swiftc -module-name BridgingApp -enforce-exclusivity\\=checked @\(fileList
            .path) -DDEBUG -import-objc-header /proj/Sources/App-Bridging-Header.h -working-directory /proj
        CompileC /dd/Objects-normal/arm64/BridgedGreeting.o /proj/Sources/BridgedGreeting.m normal arm64 objective-c com.apple.compilers.llvm.clang.1_0.compiler (in target 'BridgingApp' from project 'BridgingApp')
        CompileC /dd/Objects-normal/arm64/Other.o /proj/Other/Other.m normal arm64 objective-c com.apple.compilers.llvm.clang.1_0.compiler (in target 'OtherTarget' from project 'BridgingApp')
        """
        let captured = try #require(
            XcodeCommandCapture.parse(
                log: log, moduleName: "BridgingApp", targetName: "BridgingApp"
            )
        )
        #expect(captured.arguments.contains("-import-objc-header"))
        #expect(captured.arguments.contains("-enforce-exclusivity=checked"))
        #expect(!captured.arguments.contains { $0.hasSuffix("swiftc") })
        #expect(!captured.arguments.contains { $0.hasPrefix("@") })
        #expect(captured.swiftSources == ["/proj/Sources/App.swift", "/proj/Sources/View.swift"])
    }

    @Test("a log with driver lines for other modules only returns nil")
    func otherModulesOnly() {
        let log = """
            builtin-SwiftDriver -- /toolchain/usr/bin/swiftc -module-name OtherModule -DDEBUG
        """
        #expect(XcodeCommandCapture.parse(log: log, moduleName: "App", targetName: "App") == nil)
        #expect(XcodeCommandCapture.logsDriverInvocations(log))
        #expect(!XcodeCommandCapture.logsDriverInvocations("SwiftCompile bazel-out/x"))
    }

    @Test("escaped spaces in paths survive tokenizing")
    func escapedSpaces() {
        let tokens = XcodeCommandCapture.tokenizeShellEscaped(
            #"/usr/bin/swiftc -I /path/With\ Space/Modules -DDEBUG"#
        )
        #expect(tokens == ["/usr/bin/swiftc", "-I", "/path/With Space/Modules", "-DDEBUG"])
    }

    @Test("persisted captures round-trip and invalidate on key change")
    func persistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let command = XcodeCommandCapture.CapturedCommand(
            arguments: ["-DDEBUG"], swiftSources: ["/a.swift"]
        )
        let validity = ["/proj/project.pbxproj": Date(timeIntervalSince1970: 100)]
        XcodeCommandCapture.persist(command, at: url, validity: validity)

        let loaded = XcodeCommandCapture.loadPersisted(at: url, validity: validity)
        #expect(loaded?.arguments == ["-DDEBUG"])

        let stale = ["/proj/project.pbxproj": Date(timeIntervalSince1970: 200)]
        #expect(XcodeCommandCapture.loadPersisted(at: url, validity: stale) == nil)
    }

    @Test("normalizer drops Xcode bookkeeping incl. wrapped const-gather and vfs stat cache")
    func xcodeBookkeeping() {
        let normalized = CompileCommandNormalizer.normalize([
            "-explicit-module-build",
            "-clang-build-session-file", "/dd/Session.modulevalidation",
            "-clang-scanner-module-cache-path", "/dd/ModuleCache.noindex",
            "-sdk-module-cache-path", "/dd/ModuleCache.noindex",
            "-validate-clang-modules-once",
            "-use-frontend-parseable-output",
            "-save-temps",
            "-no-color-diagnostics",
            "-experimental-emit-module-separately",
            "-emit-const-values",
            "-Xfrontend", "-const-gather-protocols-file",
            "-Xfrontend", "/dd/App_const_extract_protocols.json",
            "-Xcc", "-ivfsstatcache", "-Xcc", "/dd/sdkstatcache",
            "-import-objc-header", "/proj/Bridging.h",
            "-DDEBUG",
        ])
        #expect(normalized == ["-import-objc-header", "/proj/Bridging.h", "-DDEBUG"])
    }
}
