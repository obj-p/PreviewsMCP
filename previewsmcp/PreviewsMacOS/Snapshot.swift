import AppKit
import Foundation

/// Encodes agent-rendered preview images as output image data.
@MainActor
public enum Snapshot {
    /// Image output format.
    public enum ImageFormat: Sendable {
        case jpeg(quality: Double)
        case png
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
            respectFlipped: true, hints: nil
        )
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
            case let .jpeg(quality):
                rep.representation(
                    using: .jpeg, properties: [.compressionFactor: NSNumber(value: quality)]
                )
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
        case .captureFailed: "Failed to capture window contents"
        case .encodingFailed: "Failed to encode screenshot"
        }
    }

    public var errorDescription: String? {
        description
    }
}
