import ArgumentParser
import Foundation
import MCP
import PreviewsCore
import PreviewsEngine

/// Batch-render every `#Preview` (and legacy `PreviewProvider`) under a file
/// or directory headless, writing an image per (preview × trait variant), a
/// JSON manifest, and an optional static HTML gallery.
///
/// This is pure orchestration over the existing primitives — discovery goes
/// through `PreviewParser` (the same AST walk `list` uses) and rendering
/// through the daemon's `preview_start` / `preview_switch` / `preview_snapshot`
/// / `preview_variants` tools. No new discovery or render engine.
///
/// One session is started per *file*, then `preview_switch` moves across the
/// file's preview indices — `switch` reuses the session's already-compiled
/// stable module and only recompiles the small per-preview overlay, so a whole
/// file costs one compile, not one-per-preview.
///
/// macOS is the clean headless lane. iOS previews need a booted simulator, so
/// they are gated: a file that resolves to the iOS platform is recorded as
/// `skipped` rather than rendered. No simulator is ever booted.
struct SnapshotAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot-all",
        abstract: "Batch-render every #Preview in a file or directory headless",
        discussion: """
        Walks a Swift file or directory, discovers every #Preview and legacy
        PreviewProvider (the same AST walk as `list`), renders each headless,
        and writes to the --out directory:

          • images/  — one image per preview (per trait variant with --variants)
          • manifest.json — one entry per rendered slot (name, file, line,
            index, variant, traits, image path, status)
          • index.html — a static gallery (with --html)

        macOS renders headless with no simulator. iOS previews are gated:
        they're recorded as `skipped` (batch iOS needs a booted simulator).

        Uses the `previewsmcp` daemon — it will be auto-started if needed.
        """
    )

    @Argument(
        help: "Swift file or directory to scan (default: current directory)",
        transform: Path.normalize
    )
    var path: String = "."

    @Option(name: [.short, .long], help: "Output directory")
    var out: String = "./preview-snapshots"

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Trait variants to render per preview. Comma-separated (light,dark) or repeated.",
            discussion: """
            Each variant is a preset name (light, dark, xSmall…accessibility5, rtl, ltr, boldText) \
            or a JSON object string with trait fields. JSON variants (starting with '{') are never \
            comma-split. With no --variants, one image is rendered per preview.
            """
        )
    )
    var variants: [String] = []

    @Flag(name: .long, help: "Also write a static HTML gallery (index.html)")
    var html: Bool = false

    @Option(name: .long, help: "Image format")
    var format: ImageFormat = .jpeg

    @Option(name: .long, help: "JPEG quality 0.0–1.0 (ignored for PNG; default 0.85)")
    var quality: Double?

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' or 'ios' (auto-detected per file if omitted)")
    var platform: CLIPlatform?

    @Option(
        name: .long,
        help: "Project root path (auto-detected if omitted)",
        transform: Path.normalize
    )
    var project: String?

    @Option(name: .long, help: "Xcode scheme name (multi-scheme .xcodeproj / .xcworkspace only)")
    var scheme: String?

    @Option(name: .long, help: "Force the build system, overriding auto-detection")
    var buildSystem: BuildSystemKind?

    @Option(
        name: .long,
        help: "Path to .previewsmcp.json config file (auto-discovered if omitted)",
        transform: Path.normalize
    )
    var config: String?

    @Flag(name: .long, help: "Emit the manifest JSON on stdout in addition to writing it")
    var json: Bool = false

    enum ImageFormat: String, ExpressibleByArgument, CaseIterable {
        case jpeg, png
    }

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("path does not exist: \(path)")
        }
        if format == .jpeg, let quality, quality >= 1.0 {
            throw ValidationError(
                "--quality must be < 1.0 when --format jpeg; use --format png for lossless output."
            )
        }
        // Resolve variant labels up front so a bad preset / duplicate label
        // fails before any compile.
        let resolvedVariants = try Self.resolveVariants(variants)

        let exitCode = try await DaemonClient.withDaemonClient(
            name: "previewsmcp-snapshot-all"
        ) { client in
            try await execute(on: client, resolvedVariants: resolvedVariants)
        }
        if exitCode != 0 { throw ExitCode(exitCode) }
    }

    // MARK: - Orchestration

    /// The daemon-driving body, factored out so tests can call it against a
    /// fake `DaemonToolCalling`. Discovers previews, renders each headless,
    /// writes the images + manifest (+ optional gallery), and returns the
    /// process exit code.
    func execute(
        on client: any DaemonToolCalling,
        resolvedVariants: [PreviewTraits.Variant]
    ) async throws -> Int32 {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let files = isDirectory.boolValue ? ListCommand.swiftFiles(in: path) : [path]
        // Slugs are relative to the walked root so images from different
        // files never collide (two files can both have a preview at index 0).
        let slugRoot = isDirectory.boolValue
            ? path : (path as NSString).deletingLastPathComponent

        let outURL = URL(fileURLWithPath: Path.normalize(out))
        let imagesDir = outURL.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)

        var entries: [ManifestEntry] = []
        var previewCount = 0
        for file in files {
            let previews: [PreviewInfo]
            do {
                previews = try PreviewParser.parse(fileAt: URL(fileURLWithPath: file))
            } catch {
                fputs("warning: skipping \(file): \(error.localizedDescription)\n", stderr)
                continue
            }
            guard !previews.isEmpty else { continue }
            previewCount += previews.count
            entries += await renderFile(
                file: file,
                previews: previews,
                slugRoot: slugRoot,
                resolvedVariants: resolvedVariants,
                imagesDir: imagesDir,
                client: client
            )
        }

        let imageCount = entries.count(where: { $0.status == .ok })
        let skippedCount = entries.count(where: { $0.status == .skipped })
        let errorCount = entries.count(where: { $0.status == .error })

        let manifest = Manifest(
            root: URL(fileURLWithPath: path).path,
            previewCount: previewCount,
            imageCount: imageCount,
            skippedCount: skippedCount,
            errorCount: errorCount,
            entries: entries
        )
        try writeManifest(manifest, to: outURL)
        if html {
            try writeGallery(manifest, to: outURL)
        }
        if json {
            try emitJSON(manifest)
        }

        fputs(
            "snapshot-all: \(imageCount) rendered, \(skippedCount) skipped, "
                + "\(errorCount) failed across \(previewCount) previews.\n",
            stderr
        )
        return Self.exitCode(ok: imageCount, failed: errorCount)
    }

    /// Render every (preview × variant) slot for one file. Starts a single
    /// session, switches across preview indices, and stops it. iOS-resolved
    /// files are skipped without touching the daemon. Failures are recorded
    /// per slot and never abort the batch.
    private func renderFile(
        file: String,
        previews: [PreviewInfo],
        slugRoot: String,
        resolvedVariants: [PreviewTraits.Variant],
        imagesDir: URL,
        client: any DaemonToolCalling
    ) async -> [ManifestEntry] {
        let fileURL = URL(fileURLWithPath: file)
        let configResult = loadProjectConfig(explicit: config, fileURL: fileURL)
        let resolvedPlatform = SnapshotCommand.resolvePlatform(
            explicit: platform,
            config: configResult?.config,
            project: project,
            fileURL: fileURL
        )
        let slug = Self.slug(for: file, root: slugRoot)

        guard resolvedPlatform == .macos else {
            return previews.flatMap { preview in
                slots(for: resolvedVariants).map { slot in
                    ManifestEntry(
                        preview: preview, file: file, slot: slot,
                        image: nil, status: .skipped,
                        error: "iOS previews are gated; batch iOS needs a booted simulator"
                    )
                }
            }
        }

        let sessionID: String
        do {
            sessionID = try await startSession(file: file, platform: resolvedPlatform, client: client)
        } catch {
            let message = (error as? DaemonToolError)?.description ?? error.localizedDescription
            return previews.flatMap { preview in
                slots(for: resolvedVariants).map { slot in
                    ManifestEntry(
                        preview: preview, file: file, slot: slot,
                        image: nil, status: .error, error: message
                    )
                }
            }
        }
        var result: [ManifestEntry] = []
        for preview in previews {
            if preview.index > 0 {
                do {
                    try await switchTo(index: preview.index, sessionID: sessionID, client: client)
                } catch {
                    let message = (error as? DaemonToolError)?.description
                        ?? error.localizedDescription
                    result += slots(for: resolvedVariants).map { slot in
                        ManifestEntry(
                            preview: preview, file: file, slot: slot,
                            image: nil, status: .error, error: message
                        )
                    }
                    continue
                }
            }
            result += await renderPreview(
                preview: preview, file: file, slug: slug,
                resolvedVariants: resolvedVariants,
                sessionID: sessionID, imagesDir: imagesDir, client: client
            )
        }
        // Await teardown before moving to the next file: a fire-and-forget
        // stop would let the batch exit with the session still live, orphaning
        // it in the daemon. The render loop above never throws out (every
        // failure is recorded as an entry), so no defer is needed.
        await stopSession(sessionID: sessionID, client: client)
        return result
    }

    /// Render every variant slot of the currently-active preview.
    private func renderPreview(
        preview: PreviewInfo,
        file: String,
        slug: String,
        resolvedVariants: [PreviewTraits.Variant],
        sessionID: String,
        imagesDir: URL,
        client: any DaemonToolCalling
    ) async -> [ManifestEntry] {
        if resolvedVariants.isEmpty {
            let slot = RenderSlot(label: nil, traits: PreviewTraits())
            do {
                let data = try await snapshot(sessionID: sessionID, client: client)
                let image = try write(data, slug: slug, index: preview.index, label: nil, to: imagesDir)
                return [ManifestEntry(
                    preview: preview, file: file, slot: slot,
                    image: image, status: .ok, error: nil
                )]
            } catch {
                let message = (error as? DaemonToolError)?.description ?? error.localizedDescription
                return [ManifestEntry(
                    preview: preview, file: file, slot: slot,
                    image: nil, status: .error, error: message
                )]
            }
        }

        do {
            let outcomes = try await captureVariants(
                sessionID: sessionID, resolvedVariants: resolvedVariants, client: client
            )
            return outcomes.map { outcome in
                let slot = RenderSlot(label: outcome.label, traits: outcome.traits)
                switch outcome.rendered {
                case let .success(data):
                    do {
                        let image = try write(
                            data, slug: slug, index: preview.index,
                            label: outcome.label, to: imagesDir
                        )
                        return ManifestEntry(
                            preview: preview, file: file, slot: slot,
                            image: image, status: .ok, error: nil
                        )
                    } catch {
                        return ManifestEntry(
                            preview: preview, file: file, slot: slot,
                            image: nil, status: .error, error: error.localizedDescription
                        )
                    }
                case let .failure(message):
                    return ManifestEntry(
                        preview: preview, file: file, slot: slot,
                        image: nil, status: .error, error: message
                    )
                }
            }
        } catch {
            let message = (error as? DaemonToolError)?.description ?? error.localizedDescription
            return slots(for: resolvedVariants).map { slot in
                ManifestEntry(
                    preview: preview, file: file, slot: slot,
                    image: nil, status: .error, error: message
                )
            }
        }
    }

    // MARK: - Daemon calls

    private func startSession(
        file: String, platform: CLIPlatform, client: any DaemonToolCalling
    ) async throws -> String {
        var startArgs: [String: Value] = [
            "filePath": .string(file),
            "previewIndex": .int(0),
            "width": .int(width),
            "height": .int(height),
            "headless": .bool(true),
            "platform": .string(platform.rawValue),
        ]
        if let project { startArgs["projectPath"] = .string(project) }
        if let scheme { startArgs["scheme"] = .string(scheme) }
        if let buildSystem { startArgs["buildSystem"] = .string(buildSystem.rawValue) }
        if let config { startArgs["config"] = .string(config) }

        let response = try await client.callToolStructured(name: "preview_start", arguments: startArgs)
        if response.isError == true {
            throw DaemonToolError.daemonError(response.content.joinedText())
        }
        guard let structured = response.structuredContent else {
            throw DaemonToolError.daemonError("preview_start response missing structuredContent")
        }
        return try structured.decode(DaemonProtocol.PreviewStartResult.self).sessionID
    }

    private func switchTo(index: Int, sessionID: String, client: any DaemonToolCalling) async throws {
        let response = try await client.callToolStructured(
            name: "preview_switch",
            arguments: ["sessionID": .string(sessionID), "previewIndex": .int(index)]
        )
        if response.isError == true {
            throw DaemonToolError.daemonError(response.content.joinedText())
        }
    }

    private func snapshot(sessionID: String, client: any DaemonToolCalling) async throws -> Data {
        let response = try await client.callToolStructured(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID), "quality": .double(resolvedQuality())]
        )
        if response.isError == true {
            throw DaemonToolError.daemonError(response.content.joinedText())
        }
        for item in response.content {
            if case let .image(base64, _, _) = item {
                guard let data = Data(base64Encoded: base64) else {
                    throw DaemonToolError.daemonError("daemon returned invalid (non-base64) image data")
                }
                return data
            }
        }
        throw DaemonToolError.daemonError("daemon response contained no image content")
    }

    /// One resolved variant's rendered outcome.
    private struct VariantOutcome {
        let label: String
        let traits: PreviewTraits
        let rendered: RenderResult

        enum RenderResult {
            case success(Data)
            case failure(String)
        }
    }

    private func captureVariants(
        sessionID: String,
        resolvedVariants: [PreviewTraits.Variant],
        client: any DaemonToolCalling
    ) async throws -> [VariantOutcome] {
        // Pass the comma-expanded tokens, not the raw `--variants` values: a
        // single "light,dark" token would reach the daemon as one unknown
        // preset. Expansion mirrors `resolveVariants`, so the daemon derives
        // the same labels we key `traitsByLabel` on below.
        let tokens = Self.expandVariantTokens(variants)
        let response = try await client.callToolStructured(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array(tokens.map { .string($0) }),
                "quality": .double(resolvedQuality()),
            ]
        )
        if response.isError == true {
            throw DaemonToolError.daemonError(response.content.joinedText())
        }
        guard let structured = response.structuredContent else {
            throw DaemonToolError.daemonError("preview_variants response missing structuredContent")
        }
        let result = try structured.decode(DaemonProtocol.VariantsResult.self)
        let traitsByLabel = Dictionary(
            resolvedVariants.map { ($0.label, $0.traits) }, uniquingKeysWith: { first, _ in first }
        )

        return result.variants.map { outcome in
            let traits = traitsByLabel[outcome.label] ?? PreviewTraits()
            if outcome.status == "ok",
               let imageIndex = outcome.imageIndex,
               imageIndex < response.content.count,
               case let .image(base64, _, _) = response.content[imageIndex],
               let data = Data(base64Encoded: base64)
            {
                return VariantOutcome(label: outcome.label, traits: traits, rendered: .success(data))
            }
            let message = outcome.status == "ok"
                ? "daemon reported ok but image data was missing or invalid"
                : (outcome.error ?? "unknown error")
            return VariantOutcome(label: outcome.label, traits: traits, rendered: .failure(message))
        }
    }

    private func stopSession(sessionID: String, client: any DaemonToolCalling) async {
        do {
            _ = try await client.callToolStructured(
                name: "preview_stop", arguments: ["sessionID": .string(sessionID)]
            )
        } catch {
            fputs("warning: failed to stop session \(sessionID): \(error)\n", stderr)
        }
    }

    // MARK: - Output

    private func write(
        _ data: Data, slug: String, index: Int, label: String?, to imagesDir: URL
    ) throws -> String {
        let ext = format == .png ? "png" : "jpg"
        let name = label.map { "\(slug)-\(index)-\($0)" } ?? "\(slug)-\(index)"
        let fileName = "\(name).\(ext)"
        try data.write(to: imagesDir.appendingPathComponent(fileName))
        return "images/\(fileName)"
    }

    private func writeManifest(_ manifest: Manifest, to outURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(manifest)
        try data.write(to: outURL.appendingPathComponent("manifest.json"))
    }

    private func writeGallery(_ manifest: Manifest, to outURL: URL) throws {
        let html = HTMLGallery.render(manifest)
        try Data(html.utf8).write(to: outURL.appendingPathComponent("index.html"))
    }

    // MARK: - Helpers

    func resolvedQuality() -> Double {
        if format == .png { return 1.0 }
        return quality ?? 0.85
    }

    /// Empty when no `--variants` were given (the single implicit "default"
    /// slot is handled by the caller). Otherwise one `RenderSlot` per variant.
    private func slots(for resolvedVariants: [PreviewTraits.Variant]) -> [RenderSlot] {
        if resolvedVariants.isEmpty {
            return [RenderSlot(label: nil, traits: PreviewTraits())]
        }
        return resolvedVariants.map { RenderSlot(label: $0.label, traits: $0.traits) }
    }

    /// Comma-split bare `--variants` tokens (light,dark) while keeping JSON
    /// object variants whole (they legitimately contain commas).
    static func expandVariantTokens(_ tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            token.hasPrefix("{") ? [token] : token.split(separator: ",").map(String.init)
        }
    }

    /// Expand and validate `--variants` tokens, resolving each to a `Variant`
    /// (label + traits) and rejecting duplicate labels.
    static func resolveVariants(_ tokens: [String]) throws -> [PreviewTraits.Variant] {
        let resolved: [PreviewTraits.Variant]
        do {
            resolved = try expandVariantTokens(tokens).map(PreviewTraits.parseVariantString)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        var seen: Set<String> = []
        for variant in resolved where !seen.insert(variant.label).inserted {
            throw ValidationError(
                "Duplicate variant label '\(variant.label)'. Provide a unique 'label' field."
            )
        }
        return resolved
    }

    /// Filename-safe slug for a source file, relative to the walked root so
    /// images from different files never collide.
    static func slug(for file: String, root: String) -> String {
        var relative = file
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if file.hasPrefix(prefix) {
            relative = String(file.dropFirst(prefix.count))
        } else {
            relative = (file as NSString).lastPathComponent
        }
        if relative.hasSuffix(".swift") {
            relative = String(relative.dropLast(".swift".count))
        }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String(relative.map { allowed.contains($0) ? $0 : "_" })
    }

    /// Exit codes mirror `variants`: 0 all rendered, 2 total failure, 1
    /// partial. Skips are neutral — an all-iOS (all-skipped) run exits 0.
    static func exitCode(ok: Int, failed: Int) -> Int32 {
        if failed == 0 { return 0 }
        return ok == 0 ? 2 : 1
    }
}

/// One resolved render target: a trait variant (or the implicit default).
private struct RenderSlot {
    let label: String?
    let traits: PreviewTraits
}

extension SnapshotAllCommand {
    /// Machine-readable batch result. `entries` is the backbone — one per
    /// rendered (preview × variant) slot, each carrying its own status.
    struct Manifest: Encodable {
        let root: String
        /// Distinct previews discovered (matches `list` output count).
        let previewCount: Int
        /// Entries with an image written to disk.
        let imageCount: Int
        let skippedCount: Int
        let errorCount: Int
        let entries: [ManifestEntry]
    }

    struct ManifestEntry: Encodable {
        let name: String?
        let file: String
        let line: Int
        let index: Int
        let variant: String?
        let traits: DaemonProtocol.TraitsDTO?
        /// Path relative to the output directory; nil for skipped/error.
        let image: String?
        let status: Status
        let error: String?

        enum Status: String, Encodable {
            case ok, skipped, error
        }

        fileprivate init(
            preview: PreviewInfo,
            file: String,
            slot: RenderSlot,
            image: String?,
            status: Status,
            error: String?
        ) {
            name = preview.name
            self.file = file
            line = preview.line
            index = preview.index
            variant = slot.label
            traits = DaemonProtocol.TraitsDTO.orNil(slot.traits)
            self.image = image
            self.status = status
            self.error = error
        }
    }
}
