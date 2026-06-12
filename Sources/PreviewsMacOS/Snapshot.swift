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
        guard
            let bitmapRep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width.rounded()),
                pixelsHigh: Int(bounds.height.rounded()),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else {
            throw SnapshotError.captureFailed
        }
        bitmapRep.size = bounds.size
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

    /// Re-encode an agent-rendered image file (PNG) to the requested output format.
    /// Used by the JIT structural path, where the snapshot is rendered in the agent,
    /// not the window. When `appearance` is given, the image is first composited
    /// over that appearance's `windowBackgroundColor`: the agent's capture only
    /// contains the hosting view's own drawing, so regions whose backdrop comes
    /// from window chrome (the navigation safe-area band) are transparent in the
    /// PNG, and white-on-dark text vanishes when a viewer lays the image on white.
    /// Without `appearance`, PNG output returns the bytes unchanged; JPEG transcodes.
    public static func encode(
        imageAt path: URL, format: ImageFormat, flattenedWith appearance: NSAppearance? = nil
    ) throws -> Data {
        let data = try Data(contentsOf: path)
        if appearance == nil, case .png = format {
            return data
        }
        guard let rep = NSBitmapImageRep(data: data) else {
            throw SnapshotError.encodingFailed
        }
        let output: NSBitmapImageRep
        if let appearance {
            output = try flatten(rep, with: appearance)
        } else {
            output = rep
        }
        switch format {
        case .png:
            guard let out = output.representation(using: .png, properties: [:]) else {
                throw SnapshotError.encodingFailed
            }
            return out
        case .jpeg(let quality):
            guard
                let out = output.representation(
                    using: .jpeg,
                    properties: [.compressionFactor: NSNumber(value: quality)]
                )
            else {
                throw SnapshotError.encodingFailed
            }
            return out
        }
    }

    private static func flatten(
        _ rep: NSBitmapImageRep, with appearance: NSAppearance
    ) throws -> NSBitmapImageRep {
        guard
            let flat = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: rep.pixelsWide,
                pixelsHigh: rep.pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let ctx = NSGraphicsContext(bitmapImageRep: flat)
        else {
            throw SnapshotError.encodingFailed
        }
        flat.size = rep.size
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
