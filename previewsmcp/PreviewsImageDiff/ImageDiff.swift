import Foundation

/// Pixel dimensions of an image, reported when a diff can't proceed.
public struct PixelSize: Equatable, Sendable, Codable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String {
        "\(width)x\(height)"
    }
}

/// An axis-aligned bounding box of changed pixels. Always returned as an
/// array so later phases can subdivide into connected components without
/// reshaping the result type.
public struct DiffRegion: Equatable, Sendable, Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Returned instead of a pixel comparison when the two images differ in
/// size — a structural change that can't be pixel-aligned.
public struct SizeMismatch: Equatable, Sendable, Codable {
    public let baseline: PixelSize
    public let current: PixelSize

    public init(baseline: PixelSize, current: PixelSize) {
        self.baseline = baseline
        self.current = current
    }
}

public struct ImageDiffResult: Sendable {
    /// Fraction of pixels within tolerance, `0.0...1.0`. `0` on a size
    /// mismatch.
    public let similarity: Double
    public let changedPixelCount: Int
    public let totalPixelCount: Int
    public let changedRegions: [DiffRegion]
    /// Non-nil only when the images differ in size; the other fields are
    /// then not meaningful and `diffImage` is nil.
    public let sizeMismatch: SizeMismatch?
    /// Changed pixels in red over a dimmed grayscale of the current image;
    /// nil on a size mismatch.
    public let diffImage: RGBAImage?
}

public enum ImageDiff {
    /// Default per-channel tolerance. Nonzero on purpose: two renders of
    /// the same view are not bit-identical — subpixel anti-aliasing and
    /// font hinting perturb edge pixels even with lossless PNG. A lossy
    /// JPEG baseline only raises this floor further.
    public static let defaultTolerance = 8

    /// Compare two already-decoded images.
    ///
    /// A pixel counts as changed when any channel (including alpha) differs
    /// by more than `tolerance` (clamped to `0...255`). `similarity` is the
    /// fraction of unchanged pixels. Pass `renderDiff: false` to skip
    /// building the diff image when only the score is needed — that avoids
    /// the per-pixel dimming work and the full-image allocation.
    public static func compare(
        _ baseline: RGBAImage,
        _ current: RGBAImage,
        tolerance: Int = defaultTolerance,
        renderDiff: Bool = true
    ) -> ImageDiffResult {
        let tolerance = max(0, min(255, tolerance))
        guard baseline.width == current.width, baseline.height == current.height else {
            return ImageDiffResult(
                similarity: 0,
                changedPixelCount: 0,
                totalPixelCount: 0,
                changedRegions: [],
                sizeMismatch: SizeMismatch(
                    baseline: PixelSize(width: baseline.width, height: baseline.height),
                    current: PixelSize(width: current.width, height: current.height)
                ),
                diffImage: nil
            )
        }

        let width = baseline.width
        let height = baseline.height
        let total = width * height
        let a = baseline.pixels
        let b = current.pixels

        var changed = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        var diff = renderDiff ? [UInt8](repeating: 0, count: total * 4) : []

        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                let dr = abs(Int(a[i]) - Int(b[i]))
                let dg = abs(Int(a[i + 1]) - Int(b[i + 1]))
                let db = abs(Int(a[i + 2]) - Int(b[i + 2]))
                let da = abs(Int(a[i + 3]) - Int(b[i + 3]))

                if max(max(dr, dg), max(db, da)) > tolerance {
                    changed += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    if renderDiff {
                        diff[i] = 255
                        diff[i + 1] = 0
                        diff[i + 2] = 0
                        diff[i + 3] = 255
                    }
                } else if renderDiff {
                    let luma = (Int(b[i]) * 299 + Int(b[i + 1]) * 587 + Int(b[i + 2]) * 114) / 1000
                    let dimmed = UInt8(luma / 2)
                    diff[i] = dimmed
                    diff[i + 1] = dimmed
                    diff[i + 2] = dimmed
                    diff[i + 3] = 255
                }
            }
        }

        let regions: [DiffRegion] = maxX >= 0
            ? [DiffRegion(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)]
            : []
        let similarity = total == 0 ? 1.0 : Double(total - changed) / Double(total)

        return ImageDiffResult(
            similarity: similarity,
            changedPixelCount: changed,
            totalPixelCount: total,
            changedRegions: regions,
            sizeMismatch: nil,
            diffImage: renderDiff ? RGBAImage(width: width, height: height, pixels: diff) : nil
        )
    }

    /// Load both images from disk and compare them.
    public static func compare(
        baselineAt baselineURL: URL,
        currentAt currentURL: URL,
        tolerance: Int = defaultTolerance,
        renderDiff: Bool = true
    ) throws -> ImageDiffResult {
        let baseline = try RGBAImage(contentsOf: baselineURL)
        let current = try RGBAImage(contentsOf: currentURL)
        return compare(baseline, current, tolerance: tolerance, renderDiff: renderDiff)
    }
}
