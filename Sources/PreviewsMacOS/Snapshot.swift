import AppKit
import Foundation

/// Captures the contents of an NSWindow as PNG image data.
@MainActor
public enum Snapshot {

    /// Capture the current contents of a window as PNG data.
    /// Uses `cacheDisplay` to render directly from the view hierarchy, which works
    /// regardless of window position (including off-screen/headless) and captures
    /// only the SwiftUI content without the title bar.
    public static func capture(window: NSWindow) throws -> Data {
        guard let contentView = window.contentView else {
            throw SnapshotError.captureFailed
        }
        let bounds = contentView.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            throw SnapshotError.captureFailed
        }
        guard let bitmapRep = contentView.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw SnapshotError.captureFailed
        }
        contentView.cacheDisplay(in: bounds, to: bitmapRep)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        return pngData
    }

    /// Capture and write to a file.
    public static func capture(window: NSWindow, to path: URL) throws {
        let data = try capture(window: window)
        try data.write(to: path)
    }
}

public enum SnapshotError: Error, LocalizedError, CustomStringConvertible {
    case captureFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .captureFailed: return "Failed to capture window contents"
        case .encodingFailed: return "Failed to encode screenshot as PNG"
        }
    }

    public var errorDescription: String? { description }
}
