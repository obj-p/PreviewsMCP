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

        let client = try await DaemonClient.connect(clientName: "previewsmcp-run")

        // Relay daemon log messages to stderr so users see build progress.
        await client.onNotification(LogMessageNotification.self) { message in
            if case .string(let text) = message.params.data {
                fputs("\(text)\n", stderr)
            }
        }

        let arguments = buildPreviewStartArguments(fileURL: fileURL)

        let response: (content: [Tool.Content], isError: Bool?)
        do {
            response = try await client.callTool(name: "preview_start", arguments: arguments)
        } catch {
            fputs("Failed to start preview: \(error)\n", stderr)
            await client.disconnect()
            throw ExitCode(1)
        }

        if response.isError == true {
            let text = textFromContent(response.content)
            fputs("Preview start failed: \(text)\n", stderr)
            await client.disconnect()
            throw ExitCode(1)
        }

        let text = textFromContent(response.content)
        guard let sessionID = extractSessionID(from: text) else {
            fputs("Unexpected daemon response (no session ID): \(text)\n", stderr)
            await client.disconnect()
            throw ExitCode(1)
        }

        if detach {
            // Scriptable: print session ID to stdout, human line to stderr.
            print(sessionID)
            fputs("session started in daemon; run `previewsmcp stop --session \(sessionID)` to end\n", stderr)
            await client.disconnect()
            return
        }

        // Attached: print the daemon's response once for user feedback, then
        // block until Ctrl+C. On signal, stop the session and exit cleanly.
        fputs("\(text)\n", stderr)
        fputs("Press Ctrl+C to stop the preview.\n", stderr)

        await blockUntilSignal()

        do {
            _ = try await client.callTool(
                name: "preview_stop",
                arguments: ["sessionID": .string(sessionID)]
            )
        } catch {
            // Best-effort. If stop fails, the daemon will still have the session;
            // user can call `kill-daemon` to clean up.
            fputs("warning: failed to stop session \(sessionID): \(error)\n", stderr)
        }
        await client.disconnect()
    }

    // MARK: - Helpers

    private func buildPreviewStartArguments(fileURL: URL) -> [String: Value] {
        var args: [String: Value] = [
            "filePath": .string(fileURL.path),
            "preview": .int(preview),
            "width": .int(width),
            "height": .int(height),
        ]
        if let platform { args["platform"] = .string(platform.rawValue) }
        if let project { args["project"] = .string(project) }
        if let scheme { args["scheme"] = .string(scheme) }
        if let device { args["device"] = .string(device) }
        if let colorScheme { args["colorScheme"] = .string(colorScheme) }
        if let dynamicTypeSize { args["dynamicTypeSize"] = .string(dynamicTypeSize) }
        if let locale { args["locale"] = .string(locale) }
        if let layoutDirection { args["layoutDirection"] = .string(layoutDirection) }
        if let legibilityWeight { args["legibilityWeight"] = .string(legibilityWeight) }
        if headless { args["headless"] = .bool(true) }
        if let config { args["config"] = .string(config) }
        return args
    }

    private func textFromContent(_ content: [Tool.Content]) -> String {
        content.compactMap { item in
            if case .text(let t) = item { return t }
            return nil
        }.joined(separator: "\n")
    }

    private func extractSessionID(from text: String) -> String? {
        let pattern = /Session ID: ([0-9a-fA-F-]{36})/
        guard let match = text.firstMatch(of: pattern) else { return nil }
        return String(match.1)
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
