import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A decoded image as row-major RGBA8 pixels: four bytes per pixel in
/// `R, G, B, A` order, `width * height * 4` bytes total.
///
/// A pure value type on purpose. Keeping the diff surface off `NSImage`
/// and off the main actor lets the comparison run headless and lets tests
/// build images pixel-by-pixel with no graphics session.
public struct RGBAImage: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(
            pixels.count == width * height * 4,
            "pixel buffer must be width * height * 4 bytes"
        )
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

public enum ImageLoadError: Error, LocalizedError {
    case unreadable(URL)
    case decodeFailed(URL)
    case contextFailed

    public var errorDescription: String? {
        switch self {
        case let .unreadable(url): "Cannot read image at \(url.path)"
        case let .decodeFailed(url): "Cannot decode image at \(url.path)"
        case .contextFailed: "Failed to create a bitmap context"
        }
    }
}

public extension RGBAImage {
    /// Decode a PNG or JPEG file into a normalized RGBA8 buffer.
    ///
    /// The source is redrawn into a device-RGB, premultiplied-last context
    /// so pixels are comparable regardless of the file's own color space,
    /// alpha layout, or row padding.
    init(contentsOf url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageLoadError.unreadable(url)
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoadError.decodeFailed(url)
        }
        try self.init(cgImage: cgImage)
    }

    internal init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        let byteCount = width * height * 4
        guard let context = RGBAImage.makeContext(width: width, height: height) else {
            throw ImageLoadError.contextFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { throw ImageLoadError.contextFailed }
        let buffer = base.bindMemory(to: UInt8.self, capacity: byteCount)
        self.init(
            width: width,
            height: height,
            pixels: Array(UnsafeBufferPointer(start: buffer, count: byteCount))
        )
    }

    /// Encode the buffer as PNG (lossless — the format for baselines and
    /// diff artifacts). For opaque pixels (alpha 255, the case for preview
    /// snapshots) a re-decode round-trips exactly. Translucent pixels are
    /// stored premultiplied by the bitmap context, so alpha < 255 loses a
    /// little precision across a premultiply/unpremultiply round-trip.
    func pngData() throws -> Data {
        guard let context = RGBAImage.makeContext(width: width, height: height),
              let base = context.data
        else { throw ImageLoadError.contextFailed }
        pixels.withUnsafeBytes { src in
            base.copyMemory(from: src.baseAddress!, byteCount: src.count)
        }
        guard let cgImage = context.makeImage() else { throw ImageLoadError.contextFailed }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, UTType.png.identifier as CFString, 1, nil
        ) else { throw ImageLoadError.contextFailed }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageLoadError.contextFailed }
        return out as Data
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}
