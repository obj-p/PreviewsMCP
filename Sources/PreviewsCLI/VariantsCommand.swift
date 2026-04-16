import ArgumentParser
import Foundation
import MCP
import PreviewsCore

/// Capture multiple snapshots of a SwiftUI preview under different trait
/// configurations by delegating to the daemon's `preview_variants` MCP
/// tool.
///
/// Magical resolution (matches `snapshot`):
///   * `--session <id>` — use that specific session.
///   * positional file — reuse an existing session for that file, or
///     spin up an ephemeral one for the capture.
///   * no flags — use the sole running session when unambiguous.
///
/// Exit codes:
///   0 — all variants captured
///   1 — partial failure (some variants captured, others failed) or
///       setup / validation error
///   2 — total failure (every variant failed)
struct VariantsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract:
            "Capture multiple snapshots of a SwiftUI preview under different trait configurations",
        discussion: """
            Reuses an existing preview session if one is running for the
            target file (or if you pass --session). Otherwise starts an
            ephemeral session, captures every variant, and cleans up.

            Each --variant is either a preset name (light, dark,
            xSmall…accessibility5, rtl, ltr, boldText) or a JSON object
            string with trait fields (colorScheme, dynamicTypeSize,
            locale, layoutDirection, legibilityWeight) and an optional
            label that determines the output filename.
            """
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "A trait variant to capture. Repeat for multiple variants.",
            discussion: """
                Either a preset name (light, dark, xSmall…accessibility5, rtl, ltr, boldText) or a JSON object \
                string with trait fields (colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight) \
                and an optional label.
                """
        )
    )
    var variant: [String] = []

    @Option(name: [.short, .long], help: "Output directory for snapshots")
    var outputDir: String = "."

    @Option(name: .long, help: "Image format")
    var format: ImageFormat = .jpeg

    @Option(name: .long, help: "JPEG quality 0.0–1.0 (ignored for PNG; default from config or 0.85)")
    var quality: Double?

    @Option(name: .long, help: "Which preview to capture (0-based index, new session only)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width (new session only)")
    var width: Int = 400

    @Option(name: .long, help: "Window height (new session only)")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' or 'ios' (auto-detected if omitted)")
    var platform: CLIPlatform?

    @Option(name: .long, help: "Project root path (auto-detected if omitted)")
    var project: String?

    @Option(
        name: .long,
        help: "Xcode scheme name (only for .xcodeproj / .xcworkspace projects with multiple schemes)"
    )
    var scheme: String?

    @Option(name: .long, help: "Simulator device UDID (for ios; auto-selects if omitted)")
    var device: String?

    @Option(
        name: .long,
        help: "Target a specific running session by UUID instead of resolving by file"
    )
    var session: String?

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    @Flag(
        name: .long,
        help: "Emit a JSON summary on stdout instead of per-variant paths (files are still written)"
    )
    var json: Bool = false

    enum ImageFormat: String, ExpressibleByArgument, CaseIterable {
        case jpeg, png
    }

    mutating func run() async throws {
        guard !variant.isEmpty else {
            throw ValidationError("At least one --variant is required")
        }
        // Guard the JPEG-quality footgun: the daemon treats quality >=
        // 1.0 as "emit PNG", which would silently write PNG bytes into
        // a .jpg file. Reject upfront so the user can either drop
        // --quality or switch to --format png.
        if format == .jpeg, let quality, quality >= 1.0 {
            throw ValidationError(
                "--quality must be < 1.0 when --format jpeg; use --format png for lossless output."
            )
        }
        if file == nil && session == nil {
            throw ValidationError(
                "Missing file argument. Pass a path or --session <uuid>."
            )
        }
        if let file {
            let fileURL = URL(fileURLWithPath: file).standardizedFileURL
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw ValidationError("File not found: \(file)")
            }
        }

        // Parse and dedupe-label-check variants locally so validation
        // errors fail before we pay the daemon roundtrip.
        let resolvedVariants: [PreviewTraits.Variant]
        do {
            resolvedVariants = try variant.map(PreviewTraits.parseVariantString)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        var seen: [String: Int] = [:]
        for (index, v) in resolvedVariants.enumerated() {
            if let prior = seen[v.label] {
                throw ValidationError(
                    "Duplicate variant label '\(v.label)' at indices \(prior) and \(index). "
                        + "Provide a unique 'label' field in JSON variants.")
            }
            seen[v.label] = index
        }

        let outputDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(
            at: outputDirURL, withIntermediateDirectories: true)

        let exitCode: Int32 = try await DaemonClient.withDaemonClient(
            name: "previewsmcp-variants"
        ) { client in
            let resolution = try await SessionResolver.resolve(
                session: session,
                file: file,
                client: client
            )

            switch resolution {
            case .found(let sessionID):
                return try await captureVariants(
                    sessionID: sessionID,
                    labels: resolvedVariants.map(\.label),
                    outputDir: outputDirURL,
                    client: client
                )
            case .notFound:
                guard let file else {
                    throw ValidationError(
                        "Session \(session ?? "?") not found. "
                            + "Pass a file path to create a new ephemeral session."
                    )
                }
                return try await captureEphemeral(
                    file: file,
                    labels: resolvedVariants.map(\.label),
                    outputDir: outputDirURL,
                    client: client
                )
            }
        }

        if exitCode != 0 { throw ExitCode(exitCode) }
    }

    // MARK: - Execution paths

    private func captureEphemeral(
        file: String,
        labels: [String],
        outputDir: URL,
        client: Client
    ) async throws -> Int32 {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        let configResult = loadProjectConfig(explicit: config, fileURL: fileURL)
        let resolvedPlatform = SnapshotCommand.resolvePlatform(
            explicit: platform,
            config: configResult?.config,
            project: project,
            fileURL: fileURL
        )

        var startArgs: [String: Value] = [
            "filePath": .string(fileURL.path),
            "previewIndex": .int(preview),
            "width": .int(width),
            "height": .int(height),
            // Capture only — never show a window during variant rendering.
            "headless": .bool(true),
            "platform": .string(resolvedPlatform.rawValue),
        ]
        if let project { startArgs["projectPath"] = .string(project) }
        if let scheme { startArgs["scheme"] = .string(scheme) }
        if let device { startArgs["deviceUDID"] = .string(device) }
        if let config { startArgs["config"] = .string(config) }

        let startResponse = try await client.callToolStructured(
            name: "preview_start", arguments: startArgs
        )
        if startResponse.isError == true {
            throw DaemonToolError.daemonError(
                "Failed to start preview: \(startResponse.content.joinedText())"
            )
        }
        guard let startStructured = startResponse.structuredContent else {
            throw DaemonToolError.daemonError(
                "preview_start response missing structuredContent"
            )
        }
        let sessionID = try startStructured
            .decode(DaemonProtocol.PreviewStartResult.self).sessionID

        do {
            let code = try await captureVariants(
                sessionID: sessionID,
                labels: labels,
                outputDir: outputDir,
                client: client
            )
            await stopEphemeralSession(sessionID: sessionID, client: client)
            return code
        } catch {
            await stopEphemeralSession(sessionID: sessionID, client: client)
            throw error
        }
    }

    /// Call `preview_variants`, decode each variant's outcome from the
    /// daemon's `structuredContent`, write successful images to disk, and
    /// surface per-variant errors to stderr.
    private func captureVariants(
        sessionID: String,
        labels: [String],
        outputDir: URL,
        client: Client
    ) async throws -> Int32 {
        let requestedQuality = resolvedQuality()

        let arguments: [String: Value] = [
            "sessionID": .string(sessionID),
            "variants": .array(variant.map { .string($0) }),
            "quality": .double(requestedQuality),
        ]
        let response = try await client.callToolStructured(
            name: "preview_variants", arguments: arguments
        )

        guard let structured = response.structuredContent else {
            throw DaemonToolError.daemonError(
                "preview_variants response missing structuredContent"
            )
        }
        let result = try structured.decode(DaemonProtocol.VariantsResult.self)

        let ext = format == .png ? "png" : "jpg"
        var successCount = 0
        var failCount = 0
        var outputEntries: [JSONVariantEntry] = []

        for outcome in result.variants {
            switch outcome.status {
            case "ok":
                guard let imageIndex = outcome.imageIndex,
                    imageIndex < response.content.count,
                    case .image(let base64, _, _) = response.content[imageIndex]
                else {
                    fputs(
                        "[error] \(outcome.label): daemon reported ok but imageIndex is invalid\n",
                        stderr
                    )
                    failCount += 1
                    outputEntries.append(
                        JSONVariantEntry(
                            label: outcome.label, status: "error",
                            path: nil, error: "invalid imageIndex"
                        )
                    )
                    continue
                }
                guard let data = Data(base64Encoded: base64) else {
                    fputs("[error] \(outcome.label): invalid base64 from daemon\n", stderr)
                    failCount += 1
                    outputEntries.append(
                        JSONVariantEntry(
                            label: outcome.label, status: "error",
                            path: nil, error: "invalid base64"
                        )
                    )
                    continue
                }
                let outURL = outputDir.appendingPathComponent("\(outcome.label).\(ext)")
                do {
                    try data.write(to: outURL)
                    if !json { print(outURL.path) }
                    successCount += 1
                    outputEntries.append(
                        JSONVariantEntry(
                            label: outcome.label, status: "ok",
                            path: outURL.path, error: nil
                        )
                    )
                } catch {
                    fputs("[error] \(outcome.label): \(error.localizedDescription)\n", stderr)
                    failCount += 1
                    outputEntries.append(
                        JSONVariantEntry(
                            label: outcome.label, status: "error",
                            path: nil, error: error.localizedDescription
                        )
                    )
                }
            default:
                // Anything other than "ok" is treated as a failure. Surface the
                // daemon's error message to stderr for the user.
                if !json {
                    let msg = outcome.error ?? "unknown error"
                    fputs("[\(outcome.index)] \(outcome.label): ERROR — \(msg)\n", stderr)
                }
                failCount += 1
                outputEntries.append(
                    JSONVariantEntry(
                        label: outcome.label, status: "error",
                        path: nil, error: outcome.error
                    )
                )
            }
        }

        // Defensive check: daemon is supposed to return one outcome per
        // requested variant. If it returned fewer, count the missing as
        // failures so the exit code reflects reality.
        let accounted = successCount + failCount
        if accounted < labels.count {
            let missing = labels.count - accounted
            fputs(
                "warning: daemon returned \(accounted) results for \(labels.count) variants\n",
                stderr
            )
            failCount += missing
        }

        if json {
            try emitJSON(
                VariantsJSONOutput(
                    variants: outputEntries,
                    successCount: successCount,
                    failCount: failCount
                )
            )
        }

        return summarize(successCount: successCount, failCount: failCount)
    }

    // MARK: - Helpers

    private func resolvedQuality() -> Double {
        // Explicit --format png overrides quality → ask daemon for PNG
        // (quality >= 1.0 is its PNG trigger).
        if format == .png { return 1.0 }
        if let quality { return quality }
        return 0.85
    }

    /// Map (success, fail) counts to the documented exit codes.
    ///   * 0 — all variants captured
    ///   * 1 — partial failure (at least one success, at least one fail)
    ///   * 2 — total failure (every variant failed)
    /// Pure + `static` so it can be unit-tested without a daemon round-trip.
    static func exitCode(successCount: Int, failCount: Int) -> Int32 {
        if failCount == 0 { return 0 }
        return failCount == (successCount + failCount) ? 2 : 1
    }

    private func summarize(successCount: Int, failCount: Int) -> Int32 {
        let total = successCount + failCount
        if failCount == 0 {
            fputs("Captured \(successCount)/\(total) variants.\n", stderr)
        } else {
            fputs(
                "Captured \(successCount)/\(total) variants (\(failCount) failed). "
                    + "See stderr for details.\n", stderr)
        }
        return Self.exitCode(successCount: successCount, failCount: failCount)
    }

    private func stopEphemeralSession(sessionID: String, client: Client) async {
        do {
            _ = try await client.callTool(
                name: "preview_stop",
                arguments: ["sessionID": .string(sessionID)]
            )
        } catch {
            fputs(
                "warning: failed to stop ephemeral session \(sessionID): \(error)\n",
                stderr
            )
        }
    }
}

/// One variant's outcome in the `--json` mode output.
struct JSONVariantEntry: Encodable {
    let label: String
    /// "ok" or "error".
    let status: String
    let path: String?
    let error: String?
}

/// `variants --json` mode top-level document.
struct VariantsJSONOutput: Encodable {
    let variants: [JSONVariantEntry]
    let successCount: Int
    let failCount: Int
}


