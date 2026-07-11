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

    func validate() throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("path does not exist: \(path)")
        }
        if let quality, !(0.0 ... 1.0).contains(quality) {
            throw ValidationError("--quality must be between 0.0 and 1.0.")
        }
        if format == .jpeg, let quality, quality >= 1.0 {
            throw ValidationError(
                "--quality must be < 1.0 when --format jpeg; use --format png for lossless output."
            )
        }
    }

    mutating func run() async throws {
        // Resolve variant labels + tokens up front so a bad preset / duplicate
        // label fails before any compile, and the split/lookup happens once.
        let plan = try VariantPlan.resolve(from: variants)

        let exitCode = try await DaemonClient.withDaemonClient(
            name: "previewsmcp-snapshot-all"
        ) { client in
            try await execute(on: client, plan: plan)
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
        plan: VariantPlan
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
        var usedSlugs: Set<String> = []
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
            // Disambiguate slugs across files: two distinct paths can map to
            // the same base slug (e.g. `Foo/Bar.swift` and `Foo_Bar.swift`),
            // which would otherwise overwrite each other's images.
            let slug = Self.uniqueSlug(for: file, root: slugRoot, used: &usedSlugs)
            entries += await renderFile(
                file: file,
                previews: previews,
                slug: slug,
                plan: plan,
                imagesDir: imagesDir,
                client: client
            )
        }

        // Tally the three statuses in a single pass over the entries.
        var imageCount = 0, skippedCount = 0, errorCount = 0
        for entry in entries {
            switch entry.status {
            case .ok: imageCount += 1
            case .skipped: skippedCount += 1
            case .error: errorCount += 1
            }
        }

        let manifest = Manifest(
            version: Self.manifestVersion,
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
        // Exit-code mapping is identical to `variants` (0 all / 2 total / 1
        // partial); skips are neutral, so an all-iOS run reports 0 failures.
        return VariantsCommand.exitCode(successCount: imageCount, failCount: errorCount)
    }

    /// Render every (preview × variant) slot for one file. Starts a single
    /// session, switches across preview indices, and stops it. iOS-resolved
    /// files are skipped without touching the daemon. Failures are recorded
    /// per slot and never abort the batch.
    private func renderFile(
        file: String,
        previews: [PreviewInfo],
        slug: String,
        plan: VariantPlan,
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

        guard resolvedPlatform == .macos else {
            return previews.flatMap {
                failedEntries(
                    preview: $0, file: file, plan: plan, status: .skipped,
                    message: "iOS previews are gated; batch iOS needs a booted simulator"
                )
            }
        }

        let sessionID: String
        do {
            sessionID = try await startSession(file: file, platform: resolvedPlatform, client: client)
        } catch {
            return previews.flatMap {
                failedEntries(
                    preview: $0, file: file, plan: plan, status: .error,
                    message: Self.message(from: error)
                )
            }
        }
        var result: [ManifestEntry] = []
        for preview in previews {
            if preview.index > 0 {
                do {
                    try await switchTo(index: preview.index, sessionID: sessionID, client: client)
                } catch {
                    result += failedEntries(
                        preview: preview, file: file, plan: plan, status: .error,
                        message: Self.message(from: error)
                    )
                    continue
                }
            }
            result += await renderPreview(
                preview: preview, file: file, slug: slug,
                plan: plan, sessionID: sessionID, imagesDir: imagesDir, client: client
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
        plan: VariantPlan,
        sessionID: String,
        imagesDir: URL,
        client: any DaemonToolCalling
    ) async -> [ManifestEntry] {
        if plan.isEmpty {
            let slot = RenderSlot(label: nil, traits: PreviewTraits())
            do {
                let data = try await snapshot(sessionID: sessionID, client: client)
                return [writtenEntry(
                    preview: preview, file: file, slot: slot,
                    data: data, slug: slug, imagesDir: imagesDir
                )]
            } catch {
                return [ManifestEntry(
                    preview: preview, file: file, slot: slot,
                    image: nil, status: .error, error: Self.message(from: error)
                )]
            }
        }

        do {
            let outcomes = try await captureVariants(
                sessionID: sessionID, plan: plan, client: client
            )
            return outcomes.map { outcome in
                switch outcome.rendered {
                case let .success(data):
                    writtenEntry(
                        preview: preview, file: file, slot: outcome.slot,
                        data: data, slug: slug, imagesDir: imagesDir
                    )
                case let .failure(message):
                    ManifestEntry(
                        preview: preview, file: file, slot: outcome.slot,
                        image: nil, status: .error, error: message
                    )
                }
            }
        } catch {
            return failedEntries(
                preview: preview, file: file, plan: plan, status: .error,
                message: Self.message(from: error)
            )
        }
    }

    /// Build one error/skip `ManifestEntry` per render slot of a preview, so a
    /// whole-preview failure still accounts for every expected slot.
    private func failedEntries(
        preview: PreviewInfo,
        file: String,
        plan: VariantPlan,
        status: ManifestEntry.Status,
        message: String
    ) -> [ManifestEntry] {
        plan.slots.map { slot in
            ManifestEntry(
                preview: preview, file: file, slot: slot,
                image: nil, status: status, error: message
            )
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

    /// One variant's rendered outcome, already paired with the render slot it
    /// belongs to (so the caller doesn't rebuild it).
    private struct VariantOutcome {
        let slot: RenderSlot
        let rendered: RenderResult

        enum RenderResult {
            case success(Data)
            case failure(String)
        }
    }

    private func captureVariants(
        sessionID: String,
        plan: VariantPlan,
        client: any DaemonToolCalling
    ) async throws -> [VariantOutcome] {
        // Pass the comma-expanded tokens, not the raw `--variants` values: a
        // single "light,dark" token would reach the daemon as one unknown
        // preset. The daemon derives the same labels we key `traitsByLabel` on.
        let response = try await client.callToolStructured(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array(plan.tokens.map { .string($0) }),
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

        let returned = result.variants.map { outcome -> VariantOutcome in
            let slot = RenderSlot(
                label: outcome.label, traits: plan.traitsByLabel[outcome.label] ?? PreviewTraits()
            )
            if outcome.status == "ok",
               let imageIndex = outcome.imageIndex,
               imageIndex >= 0, imageIndex < response.content.count,
               case let .image(base64, _, _) = response.content[imageIndex],
               let data = Data(base64Encoded: base64)
            {
                return VariantOutcome(slot: slot, rendered: .success(data))
            }
            let message = outcome.status == "ok"
                ? "daemon reported ok but image data was missing or invalid"
                : (outcome.error ?? "unknown error")
            return VariantOutcome(slot: slot, rendered: .failure(message))
        }

        // Account for any requested variant the daemon didn't return an outcome
        // for (version skew / partial response) so a missing slot surfaces as a
        // failure instead of silently vanishing from the manifest.
        let returnedLabels = Set(result.variants.map(\.label))
        let missing = plan.variants
            .filter { !returnedLabels.contains($0.label) }
            .map { variant in
                VariantOutcome(
                    slot: RenderSlot(label: variant.label, traits: variant.traits),
                    rendered: .failure("daemon returned no outcome for variant '\(variant.label)'")
                )
            }
        return returned + missing
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

    /// Write a rendered image for one slot and return the `ok` manifest entry
    /// pointing at it — or, if the write fails, an `error` entry. Shared by the
    /// no-variants and variants success paths.
    private func writtenEntry(
        preview: PreviewInfo, file: String, slot: RenderSlot,
        data: Data, slug: String, imagesDir: URL
    ) -> ManifestEntry {
        do {
            let ext = format == .png ? "png" : "jpg"
            let name = slot.label.map { "\(slug)-\(preview.index)-\($0)" } ?? "\(slug)-\(preview.index)"
            let fileName = "\(name).\(ext)"
            try data.write(to: imagesDir.appendingPathComponent(fileName))
            return ManifestEntry(
                preview: preview, file: file, slot: slot,
                image: "images/\(fileName)", status: .ok, error: nil
            )
        } catch {
            return ManifestEntry(
                preview: preview, file: file, slot: slot,
                image: nil, status: .error, error: error.localizedDescription
            )
        }
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

    /// Coerce a thrown error into a manifest message, preferring a daemon
    /// tool error's message over the generic `localizedDescription`.
    static func message(from error: Error) -> String {
        (error as? DaemonToolError)?.description ?? error.localizedDescription
    }

    /// Comma-split bare `--variants` tokens (light,dark) while keeping JSON
    /// object variants whole (they legitimately contain commas).
    static func expandVariantTokens(_ tokens: [String]) -> [String] {
        tokens.flatMap { token -> [String] in
            token.hasPrefix("{") ? [token] : token.split(separator: ",").map(String.init)
        }
    }

    private static let slugAllowed = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )

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
        return String(relative.map { slugAllowed.contains($0) ? $0 : "_" })
    }

    /// A `slug` guaranteed unique within `used`. Distinct source paths can map
    /// to the same base slug (`/` and other disallowed chars both become `_`);
    /// on a clash we append `-2`, `-3`, … so images never overwrite each other.
    static func uniqueSlug(for file: String, root: String, used: inout Set<String>) -> String {
        let base = slug(for: file, root: root)
        var candidate = base
        var suffix = 2
        while !used.insert(candidate).inserted {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
}

/// One resolved render target: a trait variant (or the implicit default).
private struct RenderSlot {
    let label: String?
    let traits: PreviewTraits
}

/// Resolved `--variants` state, computed once per invocation: the parsed
/// variants (labels + traits), the comma-expanded tokens the daemon parses,
/// and a label→traits lookup for re-associating the daemon's outcomes.
struct VariantPlan {
    fileprivate let variants: [PreviewTraits.Variant]
    fileprivate let tokens: [String]
    fileprivate let traitsByLabel: [String: PreviewTraits]

    /// True when no `--variants` were given; the caller renders one default
    /// slot per preview.
    var isEmpty: Bool {
        variants.isEmpty
    }

    /// Render slots for one preview: the implicit default when no variants
    /// were given, otherwise one per variant.
    fileprivate var slots: [RenderSlot] {
        if variants.isEmpty { return [RenderSlot(label: nil, traits: PreviewTraits())] }
        return variants.map { RenderSlot(label: $0.label, traits: $0.traits) }
    }

    /// Expand + validate the raw `--variants` tokens once, rejecting duplicate
    /// labels. Throws a `ValidationError` so a bad preset fails before compile.
    static func resolve(from raw: [String]) throws -> VariantPlan {
        let tokens = SnapshotAllCommand.expandVariantTokens(raw)
        let variants: [PreviewTraits.Variant]
        do {
            variants = try tokens.map(PreviewTraits.parseVariantString)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        var seen: Set<String> = []
        for variant in variants where !seen.insert(variant.label).inserted {
            throw ValidationError(
                "Duplicate variant label '\(variant.label)'. Provide a unique 'label' field."
            )
        }
        let traitsByLabel = Dictionary(
            variants.map { ($0.label, $0.traits) }, uniquingKeysWith: { first, _ in first }
        )
        return VariantPlan(variants: variants, tokens: tokens, traitsByLabel: traitsByLabel)
    }

    /// Ordered variant labels, for tests/inspection.
    var labels: [String] {
        variants.map(\.label)
    }
}

extension SnapshotAllCommand {
    /// Schema version of `manifest.json`. Bump when the shape changes in a
    /// non-additive way; consumers (e.g. #41 visual diff) branch on it. Purely
    /// additive fields do not require a bump.
    static let manifestVersion = 1

    /// Machine-readable batch result. `entries` is the backbone — one per
    /// rendered (preview × variant) slot, each carrying its own status.
    struct Manifest: Encodable {
        /// Schema version; see `SnapshotAllCommand.manifestVersion`.
        let version: Int
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
