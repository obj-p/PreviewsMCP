import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Produces a smaller PNG suitable for inline display when the source image
/// exceeds `threshold` pixels on its widest side. Returns the original data
/// unchanged when under the threshold or when the resize fails.
///
/// The on-disk artifact (the file the user asked for via `--output`) is
/// written at full resolution upstream — this helper only affects the bytes
/// we emit to the terminal.
enum DownscaleCG {
    static let defaultThreshold: Int = 1200
    static let defaultTargetMaxPixel: Int = 1000

    static func downscaleIfNeeded(
        _ data: Data,
        threshold: Int = defaultThreshold,
        targetMaxPixel: Int = defaultTargetMaxPixel
    ) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return failSilently(data, reason: "CGImageSource creation failed")
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else {
            return failSilently(data, reason: "pixel dimensions unavailable")
        }
        guard max(width, height) > threshold else { return data }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxPixel,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return failSilently(data, reason: "CGImageSourceCreateThumbnailAtIndex returned nil")
        }

        let outData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(outData, UTType.png.identifier as CFString, 1, nil) else {
            return failSilently(data, reason: "CGImageDestination creation failed")
        }
        CGImageDestinationAddImage(dest, thumb, nil)
        guard CGImageDestinationFinalize(dest) else {
            return failSilently(data, reason: "CGImageDestinationFinalize returned false")
        }
        return outData as Data
    }

    private static func failSilently(_ original: Data, reason: String) -> Data {
        fputs(
            "note: inline downscale failed (\(reason)); emitting full-resolution image\n",
            stderr
        )
        return original
    }
}
