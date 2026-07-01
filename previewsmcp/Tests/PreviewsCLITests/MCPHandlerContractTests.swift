import Foundation
import MCP
@testable import PreviewsCLI
import PreviewsCore
import PreviewsEngine
import PreviewsMacOS
import Testing

@Suite("MCP handler contracts")
struct MCPHandlerContractTests {
    @Test("preview_list returns structured preview metadata without launching a server")
    func previewListStructuredContent() async throws {
        let ctx = try await HandlerContractSupport.context()
        let source = try HandlerContractSupport.previewFile()

        let result = try await PreviewListHandler.handle(
            params(.previewList, ["filePath": .string(source.path)]),
            ctx: ctx
        )

        let payload = try decodeStructured(DaemonProtocol.PreviewListResult.self, from: result)
        #expect(payload.file == source.path)
        #expect(payload.previews.count == 2)
        #expect(payload.previews.map(\.index) == [0, 1])
        #expect(payload.previews.allSatisfy { !$0.active })
    }

    @Test("preview_list reports missing files as tool errors")
    func previewListMissingFile() async throws {
        let ctx = try await HandlerContractSupport.context()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-missing-\(UUID().uuidString).swift")

        let result = try await PreviewListHandler.handle(
            params(.previewList, ["filePath": .string(missing.path)]),
            ctx: ctx
        )

        #expect(result.isError == true)
        #expect(text(in: result).contains("File not found"))
        #expect(result.structuredContent == nil)
    }

    @Test("session_list returns an empty structured payload without daemon state")
    func sessionListEmptyStructuredContent() async throws {
        let ctx = try await HandlerContractSupport.context()

        let result = try await SessionListHandler.handle(params(.sessionList), ctx: ctx)

        let payload = try decodeStructured(DaemonProtocol.SessionListResult.self, from: result)
        #expect(payload.sessions.isEmpty)
        #expect(text(in: result).isEmpty)
    }

    @Test("preview_snapshot uses the routed handle and returns the requested image type")
    func previewSnapshotUsesRoutedHandle() async throws {
        let source = try HandlerContractSupport.previewFile()
        let handle = FakePreviewSessionHandle(id: "snapshot-session", sourceFile: source)
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let result = try await PreviewSnapshotHandler.handle(
            params(
                .previewSnapshot,
                ["sessionID": .string(handle.id), "quality": .double(1.0)]
            ),
            ctx: ctx
        )

        let image = try #require(imageContents(in: result).first)
        #expect(image.mimeType == "image/png")
        #expect(image.data == handle.snapshotData)
        #expect(await handle.snapshotQualities == [1.0])
    }

    @Test("preview_snapshot reports a missing session without capturing")
    func previewSnapshotMissingSession() async throws {
        let ctx = try await HandlerContractSupport.context()

        let result = try await PreviewSnapshotHandler.handle(
            params(.previewSnapshot, ["sessionID": .string("missing")]),
            ctx: ctx
        )

        #expect(result.isError == true)
        #expect(text(in: result).contains("No session found"))
    }

    @Test("preview_configure validates traits and calls reconfigure")
    func previewConfigureCallsHandle() async throws {
        let source = try HandlerContractSupport.previewFile()
        let handle = FakePreviewSessionHandle(
            id: "configure-session",
            sourceFile: source,
            traits: PreviewTraits(colorScheme: "dark", locale: "en")
        )
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let result = try await PreviewConfigureHandler.handle(
            params(
                .previewConfigure,
                [
                    "sessionID": .string(handle.id),
                    "colorScheme": .string("light"),
                    "locale": .string(""),
                ]
            ),
            ctx: ctx
        )

        #expect(result.isError != true)
        #expect(await handle.reconfigureCalls.count == 1)
        #expect(await handle.currentTraits.colorScheme == "light")
        #expect(await handle.currentTraits.locale == nil)
        #expect(text(in: result).contains("colorScheme=light"))
    }

    @Test("preview_switch returns structured active preview metadata")
    func previewSwitchStructuredContent() async throws {
        let source = try HandlerContractSupport.previewFile()
        let handle = FakePreviewSessionHandle(id: "switch-session", sourceFile: source)
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let result = try await PreviewSwitchHandler.handle(
            params(
                .previewSwitch,
                ["sessionID": .string(handle.id), "previewIndex": .int(1)]
            ),
            ctx: ctx
        )

        let payload = try decodeStructured(DaemonProtocol.SwitchResult.self, from: result)
        #expect(payload.sessionID == handle.id)
        #expect(payload.activeIndex == 1)
        #expect(payload.previews.first(where: { $0.index == 1 })?.active == true)
        #expect(await handle.switchCalls == [1])
    }

    @Test("preview_variants returns structured outcomes and restores traits")
    func previewVariantsStructuredContent() async throws {
        let source = try HandlerContractSupport.previewFile()
        let originalTraits = PreviewTraits(colorScheme: "dark")
        let handle = FakePreviewSessionHandle(
            id: "variants-session",
            sourceFile: source,
            traits: originalTraits
        )
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let result = try await PreviewVariantsHandler.handle(
            params(
                .previewVariants,
                [
                    "sessionID": .string(handle.id),
                    "variants": .array([.string("light"), .string("boldText")]),
                ]
            ),
            ctx: ctx
        )

        let payload = try decodeStructured(DaemonProtocol.VariantsResult.self, from: result)
        #expect(payload.successCount == 2)
        #expect(payload.failCount == 0)
        #expect(payload.variants.map(\.label) == ["light", "boldText"])
        #expect(payload.variants.compactMap(\.imageIndex).count == 2)
        #expect(result.content.count(where: { if case .image = $0 { true } else { false } }) == 2)
        #expect(await handle.currentTraits == originalTraits)
    }

    @Test("preview_variants supports custom JSON labels and distinct image blocks")
    func previewVariantsCustomJSONAndDistinctImages() async throws {
        let source = try HandlerContractSupport.previewFile()
        let firstImage = Data([0x01, 0x02, 0x03])
        let secondImage = Data([0x04, 0x05, 0x06])
        let handle = FakePreviewSessionHandle(
            id: "variants-custom-session",
            sourceFile: source,
            snapshotPayloads: [firstImage, secondImage]
        )
        let ctx = try await HandlerContractSupport.context(handles: [handle])
        let customJSON = #"{"colorScheme":"dark","dynamicTypeSize":"large","label":"dark-large"}"#

        let result = try await PreviewVariantsHandler.handle(
            params(
                .previewVariants,
                [
                    "sessionID": .string(handle.id),
                    "variants": .array([.string("light"), .string(customJSON)]),
                ]
            ),
            ctx: ctx
        )

        #expect(result.isError != true)
        let payload = try decodeStructured(DaemonProtocol.VariantsResult.self, from: result)
        #expect(payload.variants.map(\.label) == ["light", "dark-large"])
        let images = imageContents(in: result)
        #expect(images.map(\.data) == [firstImage, secondImage])
        #expect(images[0].data != images[1].data)
        #expect(text(in: result).contains("[1] dark-large:"))
    }

    @Test("preview_variants restores the pre-call traits")
    func previewVariantsRestoresOriginalTraits() async throws {
        let source = try HandlerContractSupport.previewFile()
        let originalTraits = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "large")
        let handle = FakePreviewSessionHandle(
            id: "variants-restore-session",
            sourceFile: source,
            traits: originalTraits
        )
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let result = try await PreviewVariantsHandler.handle(
            params(
                .previewVariants,
                [
                    "sessionID": .string(handle.id),
                    "variants": .array([.string("light")]),
                ]
            ),
            ctx: ctx
        )

        #expect(result.isError != true)
        #expect(await handle.currentTraits == originalTraits)
        let setTraitCalls = await handle.setTraitsCalls
        #expect(setTraitCalls.count == 2)
        #expect(setTraitCalls.first?.colorScheme == "light")
        #expect(setTraitCalls.last == originalTraits)
    }

    @Test("preview_variants validates empty and invalid variants before rendering")
    func previewVariantsValidationErrors() async throws {
        let source = try HandlerContractSupport.previewFile()
        let handle = FakePreviewSessionHandle(id: "variants-error-session", sourceFile: source)
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let empty = try await PreviewVariantsHandler.handle(
            params(
                .previewVariants,
                ["sessionID": .string(handle.id), "variants": .array([])]
            ),
            ctx: ctx
        )
        #expect(empty.isError == true)
        #expect(text(in: empty).contains("must not be empty"))

        let invalid = try await PreviewVariantsHandler.handle(
            params(
                .previewVariants,
                ["sessionID": .string(handle.id), "variants": .array([.string("neon")])]
            ),
            ctx: ctx
        )
        #expect(invalid.isError == true)
        #expect(text(in: invalid).contains("neon"))
        #expect(await handle.snapshotQualities.isEmpty)
    }

    @Test("preview_stop calls the routed handle")
    func previewStopCallsHandle() async throws {
        let source = try HandlerContractSupport.previewFile()
        let handle = FakePreviewSessionHandle(id: "stop-session", sourceFile: source)
        let ctx = try await HandlerContractSupport.context(handles: [handle])

        let result = try await PreviewStopHandler.handle(
            params(.previewStop, ["sessionID": .string(handle.id)]),
            ctx: ctx
        )

        #expect(result.isError != true)
        #expect(await handle.stopCallCount == 1)
        #expect(text(in: result).contains("Preview session \(handle.id) closed"))
    }
}

private enum HandlerContractSupport {
    @MainActor
    private final class StubReloader: StructuralReloader, @unchecked Sendable {
        func render(_: JITRenderBuild) async throws {}
    }

    /// None of these tests exercise `preview_start` (the only handler that
    /// reads `HandlerContext.macCompiler`), but the struct requires a real
    /// `Compiler`, whose init resolves the toolchain via `xcrun`. Sharing one
    /// instance across the suite avoids paying that resolution cost per test.
    private static let sharedCompiler = Task { try await Compiler() }

    static func context(handles: [FakePreviewSessionHandle] = []) async throws -> HandlerContext {
        let host = await MainActor.run {
            PreviewHost(makeStructuralReloader: { StubReloader() })
        }
        let iosManager = IOSSessionManager()
        let configCache = ConfigCache()
        let router = FakeSessionRouter(handles: handles)
        let registry = SessionRegistry(
            registryDir: FileManager.default.temporaryDirectory
                .appendingPathComponent("previewsmcp-handler-contract-\(UUID().uuidString)")
        )
        let compiler = try await sharedCompiler.value
        let server = Server(
            name: "previewsmcp-test",
            version: "test",
            capabilities: .init(logging: .init(), tools: .init(listChanged: false))
        )
        return HandlerContext(
            host: host,
            iosState: iosManager,
            configCache: configCache,
            router: router,
            registry: registry,
            macCompiler: compiler,
            server: server
        )
    }

    static func previewFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-handler-contract-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("ContractPreview.swift")
        try """
        import SwiftUI

        struct ContractPreview: View {
            var body: some View { Text("Contract") }
        }

        #Preview("First") {
            ContractPreview()
        }

        #Preview("Second") {
            Text("Second")
        }
        """.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}

private final class FakeSessionRouter: SessionRouting, @unchecked Sendable {
    private let handles: [String: any PreviewSessionHandle]

    init(handles: [FakePreviewSessionHandle]) {
        self.handles = Dictionary(uniqueKeysWithValues: handles.map { ($0.id, $0) })
    }

    func handle(for sessionID: String) async -> (any PreviewSessionHandle)? {
        handles[sessionID]
    }
}

private actor FakePreviewSessionHandle: PreviewSessionHandle {
    nonisolated let id: String
    nonisolated let sourceFile: URL
    nonisolated let platform: PreviewPlatform
    let snapshotData: Data
    private let snapshotPayloads: [Data]
    private(set) var traits: PreviewTraits
    private(set) var setTraitsCalls: [PreviewTraits] = []
    private(set) var reconfigureCalls: [(PreviewTraits, Set<PreviewTraits.Field>)] = []
    private(set) var switchCalls: [Int] = []
    private(set) var snapshotQualities: [Double] = []
    private(set) var stopCallCount = 0
    private var registered = true

    init(
        id: String,
        sourceFile: URL,
        platform: PreviewPlatform = .macOS,
        traits: PreviewTraits = PreviewTraits(),
        snapshotData: Data = Data([0x89, 0x50, 0x4E, 0x47]),
        snapshotPayloads: [Data]? = nil
    ) {
        self.id = id
        self.sourceFile = sourceFile
        self.platform = platform
        self.traits = traits
        self.snapshotData = snapshotData
        self.snapshotPayloads = snapshotPayloads ?? [snapshotData]
    }

    var currentTraits: PreviewTraits {
        traits
    }

    var isRegistered: Bool {
        registered
    }

    func setTraits(_ traits: PreviewTraits) async throws {
        setTraitsCalls.append(traits)
        self.traits = traits
    }

    func reconfigure(
        traits: PreviewTraits,
        clearing: Set<PreviewTraits.Field>
    ) async throws {
        reconfigureCalls.append((traits, clearing))
        self.traits = self.traits.merged(with: traits).clearing(clearing)
    }

    func switchPreview(to index: Int) async throws {
        switchCalls.append(index)
    }

    func snapshot(quality: Double) async throws -> Data {
        snapshotQualities.append(quality)
        let index = min(snapshotQualities.count - 1, snapshotPayloads.count - 1)
        return snapshotPayloads[index]
    }

    func awaitLayoutSettle() async {}

    func stop() async {
        stopCallCount += 1
        registered = false
    }
}

private func params(
    _ name: ToolName,
    _ arguments: [String: Value] = [:]
) -> CallTool.Parameters {
    CallTool.Parameters(name: name.rawValue, arguments: arguments)
}

private func decodeStructured<T: Decodable>(
    _: T.Type,
    from result: CallTool.Result
) throws -> T {
    let structured = try #require(result.structuredContent)
    let data = try JSONEncoder().encode(structured)
    return try JSONDecoder().decode(T.self, from: data)
}

private func text(in result: CallTool.Result) -> String {
    result.content.compactMap {
        if case let .text(text) = $0 { return text }
        return nil
    }.joined(separator: "\n")
}

private func imageContents(
    in result: CallTool.Result
) -> [(data: Data, mimeType: String)] {
    result.content.compactMap { item in
        if case let .image(base64, mimeType, _) = item,
           let data = Data(base64Encoded: base64)
        {
            return (data, mimeType)
        }
        return nil
    }
}
