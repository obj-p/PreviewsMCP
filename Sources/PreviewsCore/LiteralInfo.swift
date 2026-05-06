import Foundation

/// The type and value of a replaced literal.
public enum LiteralValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
    case boolean(Bool)
}

/// The kind of code region a literal lives in. Drives whether the literal-only
/// hot-reload fast path is sound: only `.swiftUI` literals can rely on
/// `@Observable DesignTimeStore` to trigger a re-render. Literals inside UIKit
/// scopes (UIView/UIViewController subclasses, UIViewRepresentable conformances,
/// or functions/properties with UIKit return types) capture the store value
/// once at construction and never observe mutation — see issue #160.
public enum LiteralRegion: Sendable, Equatable {
    case swiftUI
    case uiKit
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
    /// Whether this literal lives in a SwiftUI- or UIKit-evaluated region.
    public let region: LiteralRegion

    public init(
        id: String,
        value: LiteralValue,
        utf8Start: Int,
        utf8End: Int,
        region: LiteralRegion = .swiftUI
    ) {
        self.id = id
        self.value = value
        self.utf8Start = utf8Start
        self.utf8End = utf8End
        self.region = region
    }
}
