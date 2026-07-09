import Foundation
import MCP

/// Wire-level pieces shared by `PreviewsMCPServer` and `PreviewsMCPClient`:
/// the JSON encoder/decoder pair whose output shape the characterization
/// suite pins, frame classification, and the type-erased request shape for
/// error responses (the SDK's own AnyMethod/AnyRequest are internal).
/// `Ignored` accepts any payload shape while reading nothing, so nothing
/// here builds a throwaway tree from a several-hundred-KB frame the typed
/// second pass decodes again.
enum MCPWire {
    struct Ignored: NotRequired, Hashable, Codable {
        init() {}
        init(from _: Decoder) throws {}
    }

    struct ErasedMethod: MCP.Method {
        static let name = ""
        typealias Parameters = Ignored
        typealias Result = Ignored
    }

    /// JSON-RPC frame classification from ONE parse of an
    /// `{id?, method?, result?, error?}` envelope. Response detection wins
    /// over method presence — a frame carrying both method and result keys
    /// is a response, the characterized (and pinned) disambiguation order.
    /// Both receive loops branch on this, so the classification rules
    /// cannot diverge between the two sides. An unparseable frame carries
    /// its id when one was recoverable, so the server's parse-error reply
    /// can echo it per JSON-RPC.
    enum Classified {
        case request(id: ID, method: String)
        case response(id: ID)
        case notification(method: String)
        case unparseable(id: ID?)
    }

    static func classify(_ raw: Data) -> Classified {
        guard let envelope = try? decoder.decode(Envelope.self, from: raw) else {
            return .unparseable(id: nil)
        }
        if let id = envelope.id, envelope.hasResult || envelope.hasError {
            return .response(id: id)
        }
        return switch (envelope.id, envelope.method) {
        case let (id?, method?): .request(id: id, method: method)
        case let (nil, method?): .notification(method: method)
        default: .unparseable(id: envelope.id)
        }
    }

    /// Key PRESENCE of result/error is the response signal — `contains`,
    /// not `decodeIfPresent`, because a JSON-RPC-legal `"result": null`
    /// must still classify as a response. Payloads are never materialized
    /// here.
    private struct Envelope: Decodable {
        let id: ID?
        let method: String?
        let hasResult: Bool
        let hasError: Bool

        private enum CodingKeys: String, CodingKey {
            case id, method, result, error
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(ID.self, forKey: .id)
            method = try container.decodeIfPresent(String.self, forKey: .method)
            hasResult = container.contains(.result)
            hasError = container.contains(.error)
        }
    }

    static func pong(id: ID) -> Data? {
        try? encode(Ping.response(id: id))
    }

    static func errorResponse(id: ID, _ error: MCPError) -> Data? {
        try? encode(ErasedMethod.response(id: id, error: error))
    }

    static let decoder = JSONDecoder()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }
}
