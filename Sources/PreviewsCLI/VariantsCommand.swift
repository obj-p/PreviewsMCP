import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

/// Exit codes:
///   0 — all variants captured
///   1 — partial failure (some variants captured, others failed) or setup/validation error
///   2 — total failure (every variant failed)
struct VariantsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "variants",
        abstract:
            "Capture multiple snapshots of a SwiftUI preview under different trait configurations"
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String

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

    @Option(name: .long, help: "JPEG quality 0.0–1.0 (ignored for PNG)")
    var quality: Double = 0.85

    @Option(name: .long, help: "Which preview to capture (0-based index)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' (default) or 'ios'")
    var platform: CLIPlatform = .macos

    @Option(name: .long, help: "Project root path (auto-detected if omitted)")
    var project: String?

    @Option(name: .long, help: "Simulator device UDID (for ios; auto-selects if omitted)")
    var device: String?

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    enum ImageFormat: String, ExpressibleByArgument, CaseIterable {
        case jpeg, png
    }

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        let projectConfig = loadProjectConfig(explicit: config, fileURL: fileURL)

        guard !variant.isEmpty else {
            throw ValidationError("At least one --variant is required")
        }

        // Resolve all variants up front — validation errors are setup-time failures (exit 1).
        let resolved: [PreviewTraits.Variant]
        do {
            resolved = try variant.map(PreviewTraits.parseVariantString)
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        // Reject duplicate labels — they would silently overwrite each other on disk.
        var seen: [String: Int] = [:]
        for (index, variant) in resolved.enumerated() {
            if let prior = seen[variant.label] {
                throw ValidationError(
                    "Duplicate variant label '\(variant.label)' at indices \(prior) and \(index). "
                        + "Provide a unique 'label' field in JSON variants.")
            }
            seen[variant.label] = index
        }

        let outputDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(
            at: outputDirURL, withIntermediateDirectories: true)

        let resolvedPlatform: CLIPlatform = {
            if platform != .macos { return platform }
            if let cp = projectConfig?.platform, cp == "ios" { return .ios }
            return platform
        }()

        switch resolvedPlatform {
        case .ios:
            runIOSVariants(
                fileURL: fileURL, resolved: resolved, outputDirURL: outputDirURL,
                projectConfig: projectConfig
            )
        case .macos:
            runMacOSVariants(
                fileURL: fileURL, resolved: resolved, outputDirURL: outputDirURL,
                projectConfig: projectConfig
            )
        }
    }

    private func outputURL(in dir: URL, label: String) -> URL {
        let ext = format == .png ? "png" : "jpg"
        return dir.appendingPathComponent("\(label).\(ext)")
    }

    /// Print a per-variant failure to stderr in the same format as the MCP `preview_variants` tool.
    private func reportVariantFailure(index: Int, label: String, error: Error) {
        fputs("[\(index)] \(label): ERROR — \(error.localizedDescription)\n", stderr)
    }

    /// Print a final summary line and return the appropriate exit code.
    private func summarize(successCount: Int, failCount: Int) -> Int32 {
        let total = successCount + failCount
        if failCount == 0 {
            fputs("Captured \(successCount)/\(total) variants.\n", stderr)
            return 0
        }
        fputs(
            "Captured \(successCount)/\(total) variants (\(failCount) failed). "
                + "See stderr for details.\n", stderr)
        return failCount == total ? 2 : 1
    }

    private func runMacOSVariants(
        fileURL: URL,
        resolved: [PreviewTraits.Variant],
        outputDirURL: URL,
        projectConfig: ProjectConfig?
    ) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let projectPath = project
        let snapshotFormat: Snapshot.ImageFormat =
            format == .png ? .png : .jpeg(quality: quality)
        // Setup: detect + build (2 steps) + per variant: compile + capture (2 × N)
        let progress: any ProgressReporter = StderrProgressReporter(
            totalSteps: 2 + 2 * resolved.count)

        Task {
            // Setup phase — any failure here is a hard exit (no variants can be captured).
            let session: PreviewSession
            let sessionID: String
            do {
                let compiler = try await Compiler()
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL, projectRoot: projectRootURL, platform: .macOS,
                    progress: progress)

                session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler,
                    buildContext: buildContext,
                    traits: resolved[0].traits,
                    setupModule: projectConfig?.setup?.moduleName,
                    setupType: projectConfig?.setup?.typeName
                )
                sessionID = session.id
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                Darwin.exit(2)
            }

            // Per-variant phase — collect failures, continue past them, stream successes.
            var successCount = 0
            var failCount = 0

            for (index, variant) in resolved.enumerated() {
                do {
                    await progress.report(
                        .compilingBridge,
                        message: "Recompiling for variant \"\(variant.label)\"...")
                    let compileResult = try await session.setTraits(variant.traits)

                    try await MainActor.run {
                        try App.host.loadPreview(
                            sessionID: sessionID,
                            dylibPath: compileResult.dylibPath,
                            title: "Variant: \(variant.label)",
                            size: NSSize(width: windowWidth, height: windowHeight)
                        )
                    }

                    // Wait for SwiftUI layout
                    try await Task.sleep(for: .milliseconds(500))

                    await progress.report(
                        .capturingSnapshot,
                        message:
                            "Capturing variant \(index + 1)/\(resolved.count) \"\(variant.label)\"..."
                    )
                    let outURL = outputURL(in: outputDirURL, label: variant.label)
                    try await MainActor.run {
                        guard let window = App.host.window(for: sessionID) else {
                            throw VariantsCommandError.captureFailed(label: variant.label)
                        }
                        try Snapshot.capture(
                            window: window, format: snapshotFormat, to: outURL)
                    }
                    print(outURL.path)
                    successCount += 1
                } catch {
                    failCount += 1
                    reportVariantFailure(
                        index: index, label: variant.label, error: error)
                }
            }

            let exitCode = summarize(successCount: successCount, failCount: failCount)
            await MainActor.run { NSApp.terminate(nil) }
            // NSApp.terminate sends an event; explicit exit ensures the right code propagates.
            Darwin.exit(exitCode)
        }
    }

    private func runIOSVariants(
        fileURL: URL,
        resolved: [PreviewTraits.Variant],
        outputDirURL: URL,
        projectConfig: ProjectConfig?
    ) {
        let previewIndex = preview
        let deviceUDID = device ?? projectConfig?.device
        let projectPath = project
        let jpegQuality: Double = format == .png ? 1.0 : quality
        // Setup: detect + build (2) + iOS start (6) = 8; first variant: capture only (1); rest: compile + capture (2 × (N-1))
        let progress: any ProgressReporter = StderrProgressReporter(
            totalSteps: 7 + 2 * resolved.count)

        Task {
            // Setup phase — any failure here is a hard exit (no variants can be captured).
            let session: IOSPreviewSession
            do {
                let compiler = try await Compiler(platform: .iOS)
                let hostBuilder = try await IOSHostBuilder()
                let simulatorManager = SimulatorManager()

                let udid = try await resolveDeviceUDID(
                    provided: deviceUDID, using: simulatorManager)

                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL, projectRoot: projectRootURL, platform: .iOS,
                    progress: progress)

                session = IOSPreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    deviceUDID: udid,
                    compiler: compiler,
                    hostBuilder: hostBuilder,
                    simulatorManager: simulatorManager,
                    headless: true,
                    buildContext: buildContext,
                    traits: resolved[0].traits,
                    setupModule: projectConfig?.setup?.moduleName,
                    setupType: projectConfig?.setup?.typeName,
                    progress: progress
                )

                _ = try await session.start()
                try await Task.sleep(for: .seconds(2))
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                Darwin.exit(2)
            }

            // Per-variant phase. Whatever happens, stop the session before exiting so we
            // don't leak the simulator's preview app.
            var successCount = 0
            var failCount = 0
            var first = true

            for (index, variant) in resolved.enumerated() {
                do {
                    if !first {
                        await progress.report(
                            .compilingBridge,
                            message: "Recompiling for variant \"\(variant.label)\"...")
                        try await session.setTraits(variant.traits)
                        try await Task.sleep(for: .seconds(1))
                    }
                    first = false

                    await progress.report(
                        .capturingSnapshot,
                        message:
                            "Capturing variant \(index + 1)/\(resolved.count) \"\(variant.label)\"..."
                    )
                    let imageData = try await session.screenshot(jpegQuality: jpegQuality)
                    let outURL = outputURL(in: outputDirURL, label: variant.label)
                    try imageData.write(to: outURL)
                    print(outURL.path)
                    successCount += 1
                } catch {
                    failCount += 1
                    reportVariantFailure(
                        index: index, label: variant.label, error: error)
                    // Reset `first` so the next iteration tries to apply its traits.
                    first = false
                }
            }

            await session.stop()
            let exitCode = summarize(successCount: successCount, failCount: failCount)
            await MainActor.run { NSApp.terminate(nil) }
            Darwin.exit(exitCode)
        }
    }
}

enum VariantsCommandError: Error, LocalizedError {
    case captureFailed(label: String)

    var errorDescription: String? {
        switch self {
        case .captureFailed(let label):
            return "Failed to capture variant '\(label)': no preview window found."
        }
    }
}
