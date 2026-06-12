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
        // Pin the raster to a deterministic 1x (one pixel per point). bitmapImageRepForCachingDisplay
        // inherits the host window's backingScaleFactor — 2x on a Retina display — which made the
        // snapshot's pixel dimensions depend on which machine the daemon ran on. Building the rep
        // manually with pixel dimensions equal to the point bounds keeps output reproducible.
        guard let bitmapRep = makeRep(pixelsWide: Int(bounds.width.rounded()), pixelsHigh: Int(bounds.height.rounded()))
        else {
            throw SnapshotError.captureFailed
        }
        bitmapRep.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmapRep)
        return try data(from: bitmapRep, format: format)
    }

    /// Capture and write to a file.
    public static func capture(window: NSWindow, format: ImageFormat = .jpeg(quality: 0.85), to path: URL) throws {
        let data = try capture(window: window, format: format)
        try data.write(to: path)
    }

    /// Re-encode an agent-rendered image file (PNG) to the requested output format,
    /// composited over the appearance's `windowBackgroundColor`. Used by the JIT
    /// structural path, where the snapshot is rendered in the agent, not the window.
    /// The flatten is mandatory because the agent's capture only contains the hosting
    /// view's own drawing, so regions whose backdrop comes from window chrome (the
    /// navigation safe-area band) are transparent in the PNG, and white-on-dark text
    /// vanishes when a viewer lays the image on white.
    public static func encode(
        imageAt path: URL, format: ImageFormat, flattenedWith appearance: NSAppearance
    ) throws -> Data {
        let bytes = try Data(contentsOf: path)
        guard let rep = NSBitmapImageRep(data: bytes) else {
            throw SnapshotError.encodingFailed
        }
        return try data(from: flatten(rep, with: appearance), format: format)
    }

    private static func flatten(
        _ rep: NSBitmapImageRep, with appearance: NSAppearance
    ) throws -> NSBitmapImageRep {
        guard let flat = makeRep(pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh) else {
            throw SnapshotError.encodingFailed
        }
        flat.size = rep.size
        guard let ctx = NSGraphicsContext(bitmapImageRep: flat) else {
            throw SnapshotError.encodingFailed
        }
        let frame = NSRect(origin: .zero, size: rep.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            frame.fill()
        }
        rep.draw(
            in: frame, from: .zero, operation: .sourceOver, fraction: 1.0,
            respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return flat
    }

    private static func makeRep(pixelsWide: Int, pixelsHigh: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    private static func data(from rep: NSBitmapImageRep, format: ImageFormat) throws -> Data {
        let encoded =
            switch format {
            case .png:
                rep.representation(using: .png, properties: [:])
            case .jpeg(let quality):
                rep.representation(
                    using: .jpeg, properties: [.compressionFactor: NSNumber(value: quality)])
            }
        guard let encoded else {
            throw SnapshotError.encodingFailed
        }
        return encoded
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
