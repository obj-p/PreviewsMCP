import Foundation
import MCP

extension [Tool.Content] {
    /// Concatenate all text items in a tool result's content with newlines,
    /// skipping image and other non-text items. Convenient for CLI commands
    /// that want to display the daemon's human-readable response.
    func joinedText() -> String {
        compactMap { item in
            if case let .text(t) = item { return t }
            return nil
        }.joined(separator: "\n")
    }
}

extension CallTool.Result {
    /// Notice messages the daemon mirrored into `structuredContent.notices`
    /// (docs/phase-error-protocol.md). Empty when the response carries none.
    var noticeMessages: [String] {
        guard case let .object(fields) = structuredContent,
              case let .array(items)? = fields["notices"]
        else { return [] }
        return items.compactMap { item in
            guard case let .object(notice) = item,
                  case let .string(message)? = notice["message"]
            else { return nil }
            return message
        }
    }

    /// The response text minus notice items: what a command may print to
    /// stdout. Notices are diagnostics and go to stderr for every command
    /// (the uniform CLI rule) — call `surfaceNotices()` alongside this.
    func payloadText() -> String {
        let notices = Set(noticeMessages)
        return content.compactMap { item in
            if case let .text(t) = item, !notices.contains(t) { return t }
            return nil
        }.joined(separator: "\n")
    }

    /// Print the response's notices to stderr, message text verbatim.
    func surfaceNotices() {
        for message in noticeMessages {
            fputs("\(message)\n", stderr)
        }
    }
}

enum DecodeStructuredError: Error, CustomStringConvertible {
    case missingStructuredContent
    case decodeFailed(underlying: Error)

    var description: String {
        switch self {
        case .missingStructuredContent:
            "daemon response missing expected structuredContent payload"
        case let .decodeFailed(underlying):
            "failed to decode structuredContent: \(underlying.localizedDescription)"
        }
    }
}

/// The tool-calling surface CLI commands actually depend on: send a named
/// tool call to the daemon and get back its full result, including
/// `structuredContent`. Everything else `DaemonClient.withDaemonClient` does
/// (connect, spawn, version-mismatch restart, stall detection, log
/// forwarding) is connection lifecycle, not something command bodies touch —
/// so it stays on the concrete `PreviewsMCPClient`/`DaemonClient` and isn't
/// part of this protocol. A future test double can conform without any real
/// socket.
protocol DaemonToolCalling: Sendable {
    func callToolStructured(
        name: String,
        arguments: [String: Value]?
    ) async throws -> CallTool.Result
}

/// Write a single JSON document to stdout, followed by a newline. Used by
/// CLI commands in `--json` mode. Pretty-printed with sorted keys for
/// stable `diff`-friendly output when piping through `jq` or fixtures.
func emitJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    if let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

extension Value {
    /// Decode a `Value` (the MCP SDK's JSON type) into a `Codable` Swift
    /// type. Used by CLI commands to consume daemon `structuredContent`
    /// payloads without regex-parsing the parallel text blocks.
    func decode<T: Decodable>(_: T.Type) throws -> T {
        do {
            let data = try JSONEncoder().encode(self)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DecodeStructuredError.decodeFailed(underlying: error)
        }
    }
}
