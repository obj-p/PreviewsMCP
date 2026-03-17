import Foundation

/// The type and value of a replaced literal.
public enum LiteralValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
}

/// A single literal found in source code, with its replacement ID and value.
public struct LiteralEntry: Sendable {
    /// Sequential ID like "#0", "#1", etc.
    public let id: String
    /// The literal value.
    public let value: LiteralValue
    /// UTF-8 byte offset of the literal's start in the original source.
    public let utf8Start: Int
    /// UTF-8 byte offset of the literal's end in the original source.
    public let utf8End: Int

    public init(id: String, value: LiteralValue, utf8Start: Int, utf8End: Int) {
        self.id = id
        self.value = value
        self.utf8Start = utf8Start
        self.utf8End = utf8End
    }
}
