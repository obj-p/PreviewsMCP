import Foundation
import MCP
import PreviewsCore

enum PreviewBuildInfoHandler: ToolHandler {
    static let name: ToolName = .previewBuildInfo

    static let schema = Tool(
        name: ToolName.previewBuildInfo.rawValue,
        description:
            "Report the running server's binary path, mtime, and process start time. Returns stale=true when the on-disk binary has been replaced since the running process started — i.e., a swift build happened but the resident MCP server wasn't restarted. Used by the integration-test skill to detect stale-binary footguns before validating behavior.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    /// Build the `preview_build_info` response. Synchronous: no I/O beyond a
    /// single stat, no daemon state read.
    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let processStartISO = formatter.string(from: ProcessStartup.time)

        guard let binaryPath = resolveRunningBinaryPath() else {
            return CallTool.Result(
                content: [.text("preview_build_info: could not resolve running binary path")],
                isError: true
            )
        }

        guard let binaryMtimeDate = mtime(at: binaryPath) else {
            return CallTool.Result(
                content: [.text("preview_build_info: could not stat \(binaryPath)")],
                isError: true
            )
        }
        let binaryMtimeISO = formatter.string(from: binaryMtimeDate)
        let stale = binaryMtimeDate > ProcessStartup.time

        let payload = DaemonProtocol.BuildInfoResult(
            binaryPath: binaryPath,
            binaryMtime: binaryMtimeISO,
            processStartTime: processStartISO,
            stale: stale
        )

        let staleHint =
            stale
            ? " STALE — on-disk binary was rebuilt after this server started; restart the MCP host to pick up the new binary."
            : ""
        let text =
            "binary=\(binaryPath) mtime=\(binaryMtimeISO) processStart=\(processStartISO) stale=\(stale).\(staleHint)"

        do {
            return try CallTool.Result(
                content: [.text(text)],
                structuredContent: payload
            )
        } catch {
            // Reachable only if BuildInfoResult ever stops being Codable —
            // a programmer error worth surfacing in serve.log rather than
            // silently degrading to text-only.
            Log.error("preview_build_info: structured encoding failed: \(error)")
            return CallTool.Result(content: [.text(text)])
        }
    }
}

/// Stat `path` and return its mtime, or nil if the file is unreachable.
private func mtime(at path: String) -> Date? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
        let date = attrs[.modificationDate] as? Date
    else { return nil }
    return date
}
