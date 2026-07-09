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
    /// cannot diverge between the two sides.
    enum Classified {
        case request(id: ID, method: String)
        case response(id: ID)
        case notification(method: String)
        case unparseable
    }

    static func classify(_ raw: Data) -> Classified {
        guard let envelope = try? decoder.decode(Envelope.self, from: raw) else {
            return .unparseable
        }
        if let id = envelope.id, envelope.result != nil || envelope.error != nil {
            return .response(id: id)
        }
        return switch (envelope.id, envelope.method) {
        case let (id?, method?): .request(id: id, method: method)
        case let (nil, method?): .notification(method: method)
        default: .unparseable
        }
    }

    /// `result`/`error` decode as `Ignored` — key presence is the signal,
    /// their payloads are never materialized here.
    private struct Envelope: Decodable {
        let id: ID?
        let method: String?
        let result: Ignored?
        let error: Ignored?
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
