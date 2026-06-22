import Foundation
import Testing

@testable import PreviewsCore

/// Tests for the `Generated*Symbols.swift` resource-bundle rewrite (#151) —
/// kept in their own suite to keep `BuildSystemTests` under SwiftLint's
/// `type_body_length` cap.
@Suite("ResourceBundleRewrite")
struct ResourceBundleRewriteTests {

    /// Sample preamble emitted by Xcode at the top of `Generated*Symbols.swift`
    /// files. The recompiled-into-bridge form (`Bundle(for:)`) breaks asset
    /// lookup at runtime; the rewrite replaces it with an absolute-path lookup.
    private static let generatedSymbolsPreamble = """
        import Foundation

        #if SWIFT_PACKAGE
        private let resourceBundle = Foundation.Bundle.module
        #else
        private class ResourceBundleClass {}
        private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
        #endif

        // MARK: - Color Symbols -
        """

    @Test("rewriteResourceBundle replaces Bundle(for:) with absolute path lookup")
    func rewriteResourceBundleReplacesPreamble() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("GeneratedAssetSymbols.swift")
        try Self.generatedSymbolsPreamble.write(to: source, atomically: true, encoding: .utf8)

        let rewriteDir = tmpDir.appendingPathComponent("PreviewsMCPRewrites")
        let wrapperPath = "/path/to/Build/Products/Debug-iphonesimulator/ToDo.framework"
        let result = XcodeBuildSystem.rewriteResourceBundle(
            source: source, wrapperPath: wrapperPath, rewriteDir: rewriteDir)

        #expect(result != source, "Expected rewritten file to live under rewriteDir")
        #expect(result.path.hasPrefix(rewriteDir.path))

        let rewritten = try String(contentsOf: result, encoding: .utf8)
        #expect(rewritten.contains("Bundle(path: \"\(wrapperPath)\")"))
        #expect(rewritten.contains("Foundation.Bundle.main"))
        #expect(!rewritten.contains("Bundle(for: ResourceBundleClass.self)"))
        // The SWIFT_PACKAGE branch is preserved so SPM consumers (if this code
        // path is ever shared) still resolve via `Bundle.module`.
        #expect(rewritten.contains("Foundation.Bundle.module"))
    }

    @Test("rewriteResourceBundle skips files without the preamble")
    func rewriteResourceBundleSkipsUnrelatedFiles() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("GeneratedSomethingElse.swift")
        try "import Foundation\n// no preamble here\n".write(
            to: source, atomically: true, encoding: .utf8)

        let result = XcodeBuildSystem.rewriteResourceBundle(
            source: source,
            wrapperPath: "/some/path.framework",
            rewriteDir: tmpDir.appendingPathComponent("PreviewsMCPRewrites"))

        #expect(result == source, "Expected source URL to be returned unchanged")
    }

    @Test("rewriteResourceBundle skips files not named Generated*Symbols.swift")
    func rewriteResourceBundleSkipsNonMatchingNames() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // File contains the preamble but is named something else.
        let source = tmpDir.appendingPathComponent("MyView.swift")
        try Self.generatedSymbolsPreamble.write(to: source, atomically: true, encoding: .utf8)

        let result = XcodeBuildSystem.rewriteResourceBundle(
            source: source,
            wrapperPath: "/some/path.framework",
            rewriteDir: tmpDir.appendingPathComponent("PreviewsMCPRewrites"))

        #expect(result == source)
    }

    @Test("applyResourceBundleRewrites rewrites matching files and preserves others")
    func applyResourceBundleRewritesFanout() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let derivedFileDir = tmpDir.appendingPathComponent("Build/Intermediates/Foo.build")
        try FileManager.default.createDirectory(at: derivedFileDir, withIntermediateDirectories: true)

        // A real, on-disk "framework" — a file is enough for fileExists.
        let wrapperPath = tmpDir.appendingPathComponent("ToDo.framework").path
        try "".write(toFile: wrapperPath, atomically: true, encoding: .utf8)

        // Two Generated*Symbols.swift files (covers fan-out across multiple
        // generators — asset symbols, string symbols, etc.) plus a regular
        // source file that must not be rewritten.
        let assetSymbols = tmpDir.appendingPathComponent("GeneratedAssetSymbols.swift")
        let stringSymbols = tmpDir.appendingPathComponent("GeneratedStringSymbols.swift")
        let regularSource = tmpDir.appendingPathComponent("MyView.swift")
        try Self.generatedSymbolsPreamble.write(to: assetSymbols, atomically: true, encoding: .utf8)
        try Self.generatedSymbolsPreamble.write(to: stringSymbols, atomically: true, encoding: .utf8)
        try "import SwiftUI\nstruct MyView: View { var body: some View { Text(\"hi\") } }\n"
            .write(to: regularSource, atomically: true, encoding: .utf8)

        let settings: [String: String] = [
            "CODESIGNING_FOLDER_PATH": wrapperPath,
            "DERIVED_FILE_DIR": derivedFileDir.path,
        ]

        let result = XcodeBuildSystem.applyResourceBundleRewrites(
            sources: [assetSymbols, stringSymbols, regularSource],
            settings: settings)

        let rewriteDir = derivedFileDir.appendingPathComponent("PreviewsMCPRewrites").path
        #expect(result.count == 3)
        #expect(result[0].path.hasPrefix(rewriteDir), "asset symbols should be rewritten")
        #expect(result[1].path.hasPrefix(rewriteDir), "string symbols should be rewritten")
        #expect(result[2] == regularSource, "regular source should pass through unchanged")

        let rewrittenAsset = try String(contentsOf: result[0], encoding: .utf8)
        #expect(rewrittenAsset.contains("Bundle(path: \"\(wrapperPath)\")"))
        let rewrittenString = try String(contentsOf: result[1], encoding: .utf8)
        #expect(rewrittenString.contains("Bundle(path: \"\(wrapperPath)\")"))
    }

    @Test("applyResourceBundleRewrites returns input unchanged when CODESIGNING_FOLDER_PATH is missing")
    func applyResourceBundleRewritesMissingWrapper() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let assetSymbols = tmpDir.appendingPathComponent("GeneratedAssetSymbols.swift")
        try Self.generatedSymbolsPreamble.write(to: assetSymbols, atomically: true, encoding: .utf8)

        let result = XcodeBuildSystem.applyResourceBundleRewrites(
            sources: [assetSymbols],
            settings: ["DERIVED_FILE_DIR": tmpDir.path])
        #expect(result == [assetSymbols])
    }

    @Test("applyResourceBundleRewrites returns input unchanged when wrapper path doesn't exist")
    func applyResourceBundleRewritesNonexistentWrapper() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let assetSymbols = tmpDir.appendingPathComponent("GeneratedAssetSymbols.swift")
        try Self.generatedSymbolsPreamble.write(to: assetSymbols, atomically: true, encoding: .utf8)

        let result = XcodeBuildSystem.applyResourceBundleRewrites(
            sources: [assetSymbols],
            settings: [
                "CODESIGNING_FOLDER_PATH": "/nonexistent/path/Foo.framework",
                "DERIVED_FILE_DIR": tmpDir.path,
            ])
        // Bug-prevention: must NOT silently produce a path that leads to
        // Bundle(path:) returning nil at runtime — return original instead.
        #expect(result == [assetSymbols])
    }

    @Test("rewriteResourceBundle escapes special characters in wrapper path")
    func rewriteResourceBundleEscapesPath() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let source = tmpDir.appendingPathComponent("GeneratedAssetSymbols.swift")
        try Self.generatedSymbolsPreamble.write(to: source, atomically: true, encoding: .utf8)

        let weirdPath = #"/path/with "quotes" and \backslash/ToDo.framework"#
        let result = XcodeBuildSystem.rewriteResourceBundle(
            source: source,
            wrapperPath: weirdPath,
            rewriteDir: tmpDir.appendingPathComponent("PreviewsMCPRewrites"))

        let rewritten = try String(contentsOf: result, encoding: .utf8)
        // Backslashes and quotes must be escaped so the result is valid Swift.
        #expect(rewritten.contains(#"\\backslash"#))
        #expect(rewritten.contains(#"\"quotes\""#))
    }
}
