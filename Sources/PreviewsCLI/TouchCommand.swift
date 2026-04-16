import ArgumentParser
import Foundation
import MCP

/// Inject a tap or swipe into a running iOS simulator preview.
///
/// Forwards to the daemon's `preview_touch` MCP tool. Coordinates are in
/// device points; (0, 0) is the top-left corner of the simulator window.
/// Defaults to a tap; pass `--to-x` and `--to-y` together to perform a
/// swipe with an optional `--duration`.
///
/// iOS simulator only. Session targeting mirrors the other session-
/// scoped commands: `--session` > `--file` > the sole running session.
struct TouchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "touch",
        abstract: "Inject a tap or swipe into an iOS simulator preview",
        discussion: """
            Sends a synthetic touch event to a running iOS session.
            Coordinates are in device points; pair with `previewsmcp
            elements` to resolve labels to frames.

                previewsmcp touch 120 200
                previewsmcp touch 40 300 --to-x 300 --to-y 300
                previewsmcp touch 40 300 --to-x 300 --to-y 300 --duration 0.5

            Only available for iOS simulator sessions — this command
            errors against a macOS session.
            """
    )

    @Argument(help: "X coordinate in points (start point for swipe)")
    var x: Double

    @Argument(help: "Y coordinate in points (start point for swipe)")
    var y: Double

    @Option(name: .long, help: "End X coordinate — pair with --to-y to swipe instead of tap")
    var toX: Double?

    @Option(name: .long, help: "End Y coordinate — pair with --to-x to swipe instead of tap")
    var toY: Double?

    @Option(name: .long, help: "Swipe duration in seconds (default: 0.3)")
    var duration: Double?

    @OptionGroup var target: SessionTargetingOptions

    mutating func run() async throws {
        // Validate swipe endpoints before opening a daemon connection.
        let isSwipe: Bool
        switch (toX, toY) {
        case (nil, nil):
            isSwipe = false
        case (.some, .some):
            isSwipe = true
        default:
            throw ValidationError("--to-x and --to-y must be provided together for a swipe.")
        }
        if !isSwipe, duration != nil {
            throw ValidationError("--duration only applies to swipes (provide --to-x and --to-y).")
        }
        if let duration, duration <= 0 {
            throw ValidationError("--duration must be positive.")
        }

        try await DaemonClient.withDaemonClient(name: "previewsmcp-touch") { client in
            let resolution = try await SessionResolver.resolve(
                session: target.session,
                file: target.file,
                client: client
            )

            guard case .found(let sessionID) = resolution else {
                throw ValidationError(
                    "No session found. Start an iOS session with "
                        + "`previewsmcp run <file> --platform ios --detach` or "
                        + "pass an explicit --session <uuid>."
                )
            }

            var arguments: [String: Value] = [
                "sessionID": .string(sessionID),
                "x": .double(x),
                "y": .double(y),
            ]
            if isSwipe, let toX, let toY {
                arguments["action"] = .string("swipe")
                arguments["toX"] = .double(toX)
                arguments["toY"] = .double(toY)
                if let duration { arguments["duration"] = .double(duration) }
            }

            let response = try await client.callTool(
                name: "preview_touch",
                arguments: arguments
            )
            if response.isError == true {
                throw DaemonToolError.daemonError(response.content.joinedText())
            }

            let text = response.content.joinedText()
            if !text.isEmpty { fputs("\(text)\n", stderr) }
        }
    }
}
