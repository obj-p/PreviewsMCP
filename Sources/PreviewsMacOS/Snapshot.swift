import AppKit
import Foundation

/// Captures the contents of an NSWindow as image data.
@MainActor
public enum Snapshot {

    /// Image output format.
    public enum ImageFormat: Sendable {
        case jpeg(quality: Double)
        case png
    }

    /// Capture the current contents of a window's content view.
    /// Uses `cacheDisplay` to render directly from the view hierarchy, which works
    /// regardless of window position (including off-screen/headless) and captures
    /// only the SwiftUI content without the title bar.
    /// - Parameters:
    ///   - window: The window to capture.
    ///   - format: Output format (default: JPEG at 0.85 quality).
    public static func capture(window: NSWindow, format: ImageFormat = .jpeg(quality: 0.85)) throws -> Data {
        guard let contentView = window.contentView else {
            throw SnapshotError.captureFailed
        }
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw SnapshotError.captureFailed
        }
        // Note: bitmapImageRepForCachingDisplay produces 1x images. Off-screen headless
        // windows aren't associated with a display, so backingScaleFactor is 1.0 anyway.
        // To capture at a specific scale, create an NSBitmapImageRep manually with scaled
        // pixel dimensions. (pointfreeco/swift-snapshot-testing has the same limitation.)
        guard let bitmapRep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.captureFailed
        }
        contentView.cacheDisplay(in: bounds, to: bitmapRep)

        switch format {
        case .jpeg(let quality):
            guard
                let data = bitmapRep.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: NSNumber(value: quality)]
                )
            else {
                throw SnapshotError.encodingFailed
            }
            return data
        case .png:
            guard let data = bitmapRep.representation(using: .png, properties: [:]) else {
                throw SnapshotError.encodingFailed
            }
            return data
        }
    }

    /// Capture and write to a file.
    public static func capture(window: NSWindow, format: ImageFormat = .jpeg(quality: 0.85), to path: URL) throws {
        let data = try capture(window: window, format: format)
        try data.write(to: path)
    }
}

public enum SnapshotError: Error, LocalizedError, CustomStringConvertible {
    case captureFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .captureFailed: return "Failed to capture window contents"
        case .encodingFailed: return "Failed to encode screenshot"
        }
    }

    public var errorDescription: String? { description }
}
