import Foundation
import MCP

/// Wire-level pieces shared by `PreviewsMCPServer` and `PreviewsMCPClient`:
/// the JSON encoder/decoder pair whose output shape the characterization
/// suite pins, and type-erased shapes for the first decode pass (the SDK's
/// own AnyMethod/AnyRequest/AnyNotification are internal). Payload fields
/// decode as `Ignored`, which accepts any shape while reading nothing —
/// classification must not build a throwaway tree from a several-hundred-KB
/// frame the typed second pass decodes again. The decoder does not validate
/// the method name against `name`.
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

    struct ErasedNotification: MCP.Notification {
        static let name = ""
        typealias Parameters = Ignored
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
