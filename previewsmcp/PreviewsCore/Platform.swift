/// Target platform for preview compilation.
public enum PreviewPlatform: String, Sendable {
    case macOS
    case iOS

    /// The compiler target triple for this platform.
    public var targetTriple: String {
        switch self {
        case .macOS: return "arm64-apple-macosx14.0"
        case .iOS: return "arm64-apple-ios17.0-simulator"
        }
    }
}
