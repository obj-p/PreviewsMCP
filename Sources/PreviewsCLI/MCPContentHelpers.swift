import Foundation
import MCP

extension Array where Element == Tool.Content {
    /// Concatenate all text items in a tool result's content with newlines,
    /// skipping image and other non-text items. Convenient for CLI commands
    /// that want to display the daemon's human-readable response.
    func joinedText() -> String {
        compactMap { item in
            if case .text(let t) = item { return t }
            return nil
        }.joined(separator: "\n")
    }
}

/// Result shape the `client.callTool(...)` tuple overload returns. The MCP
/// SDK drops `structuredContent` from that overload; CLI commands that need
/// the structured payload go through `callToolStructured` on `DaemonClient`.
typealias CallToolTuple = (content: [Tool.Content], isError: Bool?)

enum DecodeStructuredError: Error, CustomStringConvertible {
    case missingStructuredContent
    case decodeFailed(underlying: Error)

    var description: String {
        switch self {
        case .missingStructuredContent:
            return "daemon response missing expected structuredContent payload"
        case .decodeFailed(let underlying):
            return "failed to decode structuredContent: \(underlying.localizedDescription)"
        }
    }
}

extension Client {
    /// Call an MCP tool and return the full `CallTool.Result` including
    /// `structuredContent`. The SDK's primary `callTool(name:arguments:)`
    /// overload drops that field; CLI commands that need the structured
    /// payload go through this helper instead.
    func callToolStructured(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> CallTool.Result {
        let context: RequestContext<CallTool.Result> = try await callTool(
            name: name, arguments: arguments
        )
        return try await context.value
    }
}

/// Write a single JSON document to stdout, followed by a newline. Used by
/// CLI commands in `--json` mode. Pretty-printed with sorted keys for
/// stable `diff`-friendly output when piping through `jq` or fixtures.
func emitJSON<T: Encodable>(_ value: T) throws {
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
