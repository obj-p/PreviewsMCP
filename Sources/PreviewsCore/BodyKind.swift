import Foundation

/// The kind of view returned by the outermost expression of a `#Preview` closure.
///
/// Reported by the dylib's `previewBodyKind` `@_cdecl` symbol via Swift overload
/// resolution against `__PreviewBodyKindProbe.detect`. Used by `IOSPreviewSession`
/// to gate the literal-only hot-reload fast path: that path only works for SwiftUI
/// bodies because UIKit doesn't observe `DesignTimeStore` mutations (#160).
///
/// Crosses two boundaries with two different encodings:
///
/// - `rawCode: Int32` — the numeric value emitted by the generated probe. The
///   integers `1`/`2`/`3` are hardcoded in `PreviewBridgeSource.swift`'s template
///   and in `IOSHostAppSource.swift`'s switch (both are source-template strings
///   that don't link `PreviewsCore`). `BodyKindCodeContractTests` locks the
///   mapping so a future renumbering here breaks at test time rather than as a
///   silent protocol skew.
/// - `wireValue: String` — the identifier sent over the daemon↔host TCP socket.
public enum BodyKind: Sendable, Equatable {
    case swiftUI
    case uiView
    case uiViewController

    /// Numeric encoding returned by the dylib's `previewBodyKind` `@_cdecl`
    /// symbol. Mirrors the order of `__PreviewBodyKindProbe.detect` overloads.
    public var rawCode: Int32 {
        switch self {
        case .swiftUI: return 1
        case .uiView: return 2
        case .uiViewController: return 3
        }
    }

    /// Decodes the value returned by the probe symbol. Returns nil for
    /// unrecognized codes — callers should fall back to a safe default.
    public init?(rawCode: Int32) {
        switch rawCode {
        case 1: self = .swiftUI
        case 2: self = .uiView
        case 3: self = .uiViewController
        default: return nil
        }
    }

    /// String identifier used on the daemon↔host socket protocol.
    public var wireValue: String {
        switch self {
        case .swiftUI: return "swiftUI"
        case .uiView: return "uiView"
        case .uiViewController: return "uiViewController"
        }
    }

    /// Decodes a `kind` field from an `init`/`reload` ack. Returns nil for
    /// unrecognized values — callers should fall back to a safe default.
    public init?(wireValue: String) {
        switch wireValue {
        case "swiftUI": self = .swiftUI
        case "uiView": self = .uiView
        case "uiViewController": self = .uiViewController
        default: return nil
        }
    }
}
