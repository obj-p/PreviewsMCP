import ArgumentParser
import Foundation
import MCP
import PreviewsCore

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Compile and display a live SwiftUI preview",
        discussion: """
            Starts a preview session in the previewsmcp daemon. The daemon owns
            the preview window and file watcher; this command is a lightweight
            client. Starts the daemon automatically if not running.

            By default, blocks until Ctrl+C, which stops the session. Pass
            `--detach` to start the session and exit (session UUID is printed
            to stdout for use with other commands).
            """
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String

    @Option(name: .long, help: "Which preview to show (0-based index)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
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

    @Option(name: .long, help: "Color scheme: 'light' or 'dark'")
    var colorScheme: String?

    @Option(name: .long, help: "Dynamic Type size (e.g., 'large', 'accessibility3')")
    var dynamicTypeSize: String?

    @Option(name: .long, help: "Locale identifier (e.g., 'en', 'ar', 'ja-JP')")
    var locale: String?

    @Option(name: .long, help: "Layout direction: 'leftToRight' or 'rightToLeft'")
    var layoutDirection: String?

    @Option(name: .long, help: "Legibility weight: 'regular' or 'bold'")
    var legibilityWeight: String?

    @Flag(name: .long, help: "Hide Simulator.app GUI (iOS only)")
    var headless: Bool = false

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    @Flag(
        name: .long,
        help: "Start the session and exit; session keeps running in the daemon"
    )
    var detach: Bool = false

    @Flag(
        name: .long,
        help: "Emit the daemon's structured response as JSON on stdout (--detach only)"
    )
    var json: Bool = false

    mutating func run() async throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        // Local trait validation — fail fast before reaching the daemon.
        do {
            _ = try PreviewTraits.validated(
                colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
                locale: locale, layoutDirection: layoutDirection,
                legibilityWeight: legibilityWeight
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        if json, !detach {
            throw ValidationError("--json requires --detach (attached mode exits on Ctrl+C).")
        }

        try await DaemonClient.withDaemonClient(name: "previewsmcp-run") { client in
            let arguments = buildPreviewStartArguments(fileURL: fileURL)

            let response: CallTool.Result
            do {
                response = try await client.callToolStructured(
                    name: "preview_start", arguments: arguments
                )
            } catch {
                fputs("Failed to start preview: \(error)\n", stderr)
                throw ExitCode(1)
            }

            if response.isError == true {
                fputs("Preview start failed: \(response.content.joinedText())\n", stderr)
                throw ExitCode(1)
            }

            guard let structured = response.structuredContent else {
                fputs("Unexpected daemon response (no structuredContent)\n", stderr)
                throw ExitCode(1)
            }
            let start: DaemonProtocol.PreviewStartResult
            do {
                start = try structured.decode(DaemonProtocol.PreviewStartResult.self)
            } catch {
                fputs("Failed to decode daemon response: \(error)\n", stderr)
                throw ExitCode(1)
            }
            let sessionID = start.sessionID
            let text = response.content.joinedText()

            if detach {
                if json {
                    try emitJSON(structured)
                } else {
                    // Scriptable: print session ID to stdout, human line to stderr.
                    print(sessionID)
                }
                fputs("session \(sessionID) started in daemon\n", stderr)
                return
            }

            // Attached: print the daemon's response once for user feedback,
            // then block until Ctrl+C. On signal, stop the session and
            // exit cleanly.
            fputs("\(text)\n", stderr)
            fputs("Press Ctrl+C to stop the preview.\n", stderr)

            await blockUntilSignal()

            do {
                _ = try await client.callTool(
                    name: "preview_stop",
                    arguments: ["sessionID": .string(sessionID)]
                )
            } catch {
                // Best-effort — the session may still be alive in the daemon.
                // Surface the session ID so the user can target it with `stop`
                // or fall back to `kill-daemon` to wipe everything.
                fputs(
                    "warning: failed to stop session \(sessionID): \(error)\n"
                        + "  session may still be running in the daemon; "
                        + "run `previewsmcp kill-daemon` to clean up.\n",
                    stderr
                )
            }
        }
    }

    // MARK: - Helpers

    private func buildPreviewStartArguments(fileURL: URL) -> [String: Value] {
        var args: [String: Value] = [
            "filePath": .string(fileURL.path),
            "previewIndex": .int(preview),
            "width": .int(width),
            "height": .int(height),
        ]
        if let platform { args["platform"] = .string(platform.rawValue) }
        if let project { args["projectPath"] = .string(project) }
        if let scheme { args["scheme"] = .string(scheme) }
        if let device { args["deviceUDID"] = .string(device) }
        if let colorScheme { args["colorScheme"] = .string(colorScheme) }
        if let dynamicTypeSize { args["dynamicTypeSize"] = .string(dynamicTypeSize) }
        if let locale { args["locale"] = .string(locale) }
        if let layoutDirection { args["layoutDirection"] = .string(layoutDirection) }
        if let legibilityWeight { args["legibilityWeight"] = .string(legibilityWeight) }
        // Always send headless — both the macOS and iOS daemon paths default
        // `extractOptionalBool("headless") ?? true` when the key is absent, so
        // dropping the key on `--headless=false` would silently force a headless
        // window and a CLI user would never see a visible simulator.
        args["headless"] = .bool(headless)
        return args
    }

}

/// Block the calling task until the process receives SIGINT or SIGTERM.
/// Returns immediately after the first signal is delivered.
private func blockUntilSignal() async {
    // Suppress default terminate-on-signal behavior; DispatchSource handles it.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let box = ContinuationBox(continuation)
        let sources = [
            DispatchSource.makeSignalSource(signal: SIGINT, queue: .main),
            DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main),
        ]
        for source in sources {
            source.setEventHandler { box.resumeOnce() }
            source.resume()
        }
        box.retainSources(sources)
    }
}

/// Ensures a continuation is resumed exactly once, regardless of how many
/// signals arrive or which source fires first.
private final class ContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var retainedSources: [DispatchSourceSignal] = []

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func retainSources(_ sources: [DispatchSourceSignal]) {
        lock.lock(); defer { lock.unlock() }
        retainedSources = sources
    }

    func resumeOnce() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
