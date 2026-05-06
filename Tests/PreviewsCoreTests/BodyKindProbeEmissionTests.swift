import Foundation
import Testing

@testable import PreviewsCore

/// Tests covering emission and runtime behavior of the `previewBodyKind`
/// `@_cdecl` symbol added by `BridgeGenerator` for issue #160.
///
/// Lives in its own file (rather than in `BridgeGeneratorTraitsTests`) to keep
/// the host struct under SwiftLint's `type_body_length` ceiling and to give
/// the body-kind probe a focused home distinct from trait-injection tests.
@Suite("BridgeGenerator body-kind probe emission")
struct BodyKindProbeEmissionTests {

    @Test("Body-kind probe is emitted in generated iOS source")
    func bodyKindProbeEmittedIOS() {
        let source = """
            import SwiftUI
            #Preview { Text("hi") }
            """
        let previews = PreviewParser.parse(source: source)
        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: source,
            closureBody: previews[0].closureBody,
            platform: .iOS
        )
        #expect(combined.contains("__PreviewBodyKindProbe"))
        #expect(combined.contains("@_cdecl(\"previewBodyKind\")"))
        #expect(combined.contains("public func previewBodyKind() -> Int32"))
    }

    @Test("Body-kind probe is emitted in generated macOS source")
    func bodyKindProbeEmittedMacOS() {
        let source = """
            import SwiftUI
            #Preview { Text("hi") }
            """
        let previews = PreviewParser.parse(source: source)
        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: source,
            closureBody: previews[0].closureBody,
            platform: .macOS
        )
        #expect(combined.contains("__PreviewBodyKindProbe"))
        #expect(combined.contains("@_cdecl(\"previewBodyKind\")"))
    }

    @Test("Body-kind probe is also emitted by Tier-1 bridge-only generator")
    func bodyKindProbeEmittedBridgeOnly() {
        let bridgeOnly = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyModule",
            closureBody: "MyView()",
            platform: .iOS
        )
        #expect(bridgeOnly.contains("__PreviewBodyKindProbe"))
        #expect(bridgeOnly.contains("@_cdecl(\"previewBodyKind\")"))
    }

    @Test("Compiled iOS UIView dylib exports previewBodyKind symbol")
    func compiledUIViewDylibExportsBodyKindSymbol() async throws {
        let uiViewSource = """
            import SwiftUI
            import UIKit
            final class ExampleUIView: UIView {}
            #Preview { ExampleUIView() }
            """
        let previews = PreviewParser.parse(source: uiViewSource)
        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: uiViewSource,
            closureBody: previews[0].closureBody,
            platform: .iOS
        )
        let compiler = try await Compiler(platform: .iOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "UIViewProbeTest_\(Int.random(in: 0...999999))"
        )

        // `nm -gU` lists exported global symbols. The @_cdecl name appears
        // with a leading underscore in Mach-O symbol tables.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gU", result.dylibPath.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output =
            String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(
            output.contains("_previewBodyKind"),
            "Expected _previewBodyKind in dylib exports; got:\n\(output)")
    }

    @Test("Body-kind probe returns 1 (SwiftUI) at runtime for SwiftUI body")
    func bodyKindProbeReturnsOneForSwiftUI() async throws {
        // macOS-targeted compile so we can dlopen the dylib in this test process.
        // The macOS probe variant only has the SwiftUI overload, so any compilable
        // body returns 1 — but that still validates emission and dispatch.
        let source = """
            import SwiftUI
            #Preview { Text("hi") }
            """
        let previews = PreviewParser.parse(source: source)
        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: source,
            closureBody: previews[0].closureBody,
            platform: .macOS
        )
        let compiler = try await Compiler(platform: .macOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "BodyKindRuntimeTest_\(Int.random(in: 0...999999))"
        )

        guard let handle = dlopen(result.dylibPath.path, RTLD_NOW | RTLD_LOCAL) else {
            let err = String(cString: dlerror())
            Issue.record("dlopen failed: \(err)")
            return
        }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "previewBodyKind") else {
            Issue.record("previewBodyKind symbol missing")
            return
        }
        typealias BodyKindFunc = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: BodyKindFunc.self)
        #expect(fn() == BodyKind.swiftUI.rawCode, "Expected SwiftUI body kind code")
    }

    // BodyKind.rawCode mappings are pinned by `BodyKindCodeContractTests`.
}
