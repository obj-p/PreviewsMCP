import AppKit
import Foundation

/// Captures the contents of an NSWindow as PNG image data.
@MainActor
public enum Snapshot {

    /// Capture the current contents of a window as PNG data.
    public static func capture(window: NSWindow) throws -> Data {
        guard let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming]
        ) else {
            throw SnapshotError.captureFailed
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
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

public enum SnapshotError: Error, CustomStringConvertible {
    case captureFailed
    case encodingFailed

    public var description: String {
        switch self {
        case .captureFailed: return "Failed to capture window contents"
        case .encodingFailed: return "Failed to encode screenshot as PNG"
        }
    }
}
