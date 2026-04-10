import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

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
        parsing: .singleValue,
        help: ArgumentHelp(
            "A trait variant to capture. Repeat for multiple variants.",
            discussion: """
                Either a preset name (light, dark, xSmall…accessibility5) or a JSON object \
                string like '{"colorScheme":"dark","dynamicTypeSize":"large","label":"dark+large"}'.
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

    enum ImageFormat: String, ExpressibleByArgument, CaseIterable {
        case jpeg, png
    }

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        guard !variant.isEmpty else {
            throw ValidationError("At least one --variant is required")
        }

        // Resolve all variants up front to fail fast on invalid input.
        let resolved: [(traits: PreviewTraits, label: String)]
        do {
            resolved = try variant.map(Self.resolveVariant)
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        // Reject duplicate labels — they would overwrite each other on disk.
        var seen: Set<String> = []
        for (_, label) in resolved {
            if !seen.insert(label).inserted {
                throw ValidationError(
                    "Duplicate variant label '\(label)'. Provide a unique 'label' field in JSON variants.")
            }
        }

        let outputDirURL = URL(fileURLWithPath: outputDir)
        try FileManager.default.createDirectory(
            at: outputDirURL, withIntermediateDirectories: true)

        switch platform {
        case .ios:
            runIOSVariants(fileURL: fileURL, resolved: resolved, outputDirURL: outputDirURL)
        case .macos:
            runMacOSVariants(fileURL: fileURL, resolved: resolved, outputDirURL: outputDirURL)
        }
    }

    /// Resolve a variant string (preset name or JSON object) to traits and a label.
    static func resolveVariant(_ str: String) throws -> (traits: PreviewTraits, label: String) {
        if let traits = PreviewTraits.fromPreset(str) {
            return (traits, str)
        }
        guard let data = str.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw VariantsCommandError.unknownPreset(str)
        }
        let colorScheme = json["colorScheme"] as? String
        let dynamicTypeSize = json["dynamicTypeSize"] as? String
        let traits = try PreviewTraits.validated(
            colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)
        if traits.isEmpty {
            throw VariantsCommandError.emptyVariantObject
        }
        let label = (json["label"] as? String) ?? Self.defaultLabel(traits)
        return (traits, label)
    }

    /// Filename-friendly label derived from non-nil trait values, joined with `+`.
    static func defaultLabel(_ traits: PreviewTraits) -> String {
        var parts: [String] = []
        if let cs = traits.colorScheme { parts.append(cs) }
        if let dts = traits.dynamicTypeSize { parts.append(dts) }
        return parts.joined(separator: "+")
    }

    private func outputURL(in dir: URL, label: String) -> URL {
        let ext = format == .png ? "png" : "jpg"
        return dir.appendingPathComponent("\(label).\(ext)")
    }

    private func runMacOSVariants(
        fileURL: URL,
        resolved: [(traits: PreviewTraits, label: String)],
        outputDirURL: URL
    ) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let projectPath = project
        let snapshotFormat: Snapshot.ImageFormat =
            format == .png ? .png : .jpeg(quality: quality)

        Task {
            do {
                let compiler = try await Compiler()

                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL, projectRoot: projectRootURL, platform: .macOS)

                // Single session, recompiled per variant via setTraits.
                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler,
                    buildContext: buildContext,
                    traits: resolved[0].traits
                )
                let sessionID = session.id

                fputs(
                    "Capturing \(resolved.count) variant(s) of \(fileURL.lastPathComponent)...\n",
                    stderr)

                // Compile + display the first variant via the normal compile() path,
                // then loop using setTraits() (which also recompiles).
                var first = true
                for (traits, label) in resolved {
                    let compileResult: CompileResult
                    if first {
                        compileResult = try await session.compile()
                        first = false
                    } else {
                        compileResult = try await session.setTraits(traits)
                    }

                    try await MainActor.run {
                        try App.host.loadPreview(
                            sessionID: sessionID,
                            dylibPath: compileResult.dylibPath,
                            title: "Variant: \(label)",
                            size: NSSize(width: windowWidth, height: windowHeight)
                        )
                    }

                    // Wait for SwiftUI layout
                    try await Task.sleep(for: .milliseconds(500))

                    let outURL = outputURL(in: outputDirURL, label: label)
                    try await MainActor.run {
                        guard let window = App.host.window(for: sessionID) else {
                            throw VariantsCommandError.captureFailed(label: label)
                        }
                        try Snapshot.capture(
                            window: window, format: snapshotFormat, to: outURL)
                    }
                    print(outURL.path)
                }

                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }
    }

    private func runIOSVariants(
        fileURL: URL,
        resolved: [(traits: PreviewTraits, label: String)],
        outputDirURL: URL
    ) {
        let previewIndex = preview
        let deviceUDID = device
        let projectPath = project
        let jpegQuality: Double = format == .png ? 1.0 : quality

        Task {
            do {
                let compiler = try await Compiler(platform: .iOS)
                let hostBuilder = try await IOSHostBuilder()
                let simulatorManager = SimulatorManager()

                let udid = try await resolveDeviceUDID(
                    provided: deviceUDID, using: simulatorManager)

                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL, projectRoot: projectRootURL, platform: .iOS)

                let session = IOSPreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    deviceUDID: udid,
                    compiler: compiler,
                    hostBuilder: hostBuilder,
                    simulatorManager: simulatorManager,
                    headless: true,
                    buildContext: buildContext,
                    traits: resolved[0].traits
                )

                fputs(
                    "Capturing \(resolved.count) variant(s) on simulator \(udid)...\n", stderr)
                _ = try await session.start()
                try await Task.sleep(for: .seconds(2))

                var first = true
                for (traits, label) in resolved {
                    if !first {
                        try await session.setTraits(traits)
                        try await Task.sleep(for: .seconds(1))
                    }
                    first = false

                    let imageData = try await session.screenshot(jpegQuality: jpegQuality)
                    let outURL = outputURL(in: outputDirURL, label: label)
                    try imageData.write(to: outURL)
                    print(outURL.path)
                }

                await session.stop()
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                fputs("Error: \(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
        }
    }
}

enum VariantsCommandError: Error, LocalizedError {
    case unknownPreset(String)
    case emptyVariantObject
    case captureFailed(label: String)

    var errorDescription: String? {
        switch self {
        case .unknownPreset(let name):
            let presets = PreviewTraits.allPresetNames.sorted().joined(separator: ", ")
            return
                "Unknown variant '\(name)'. Expected a preset name (\(presets)) or a JSON object string."
        case .emptyVariantObject:
            return
                "Variant object must specify at least one trait (colorScheme or dynamicTypeSize)."
        case .captureFailed(let label):
            return "Failed to capture variant '\(label)': no preview window found."
        }
    }
}
