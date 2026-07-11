import Foundation
@testable import PreviewsImageDiff
import Testing

@Suite("ImageDiff")
struct ImageDiffTests {
    /// A solid-color image, built pixel-by-pixel so the comparison math is
    /// exercised with no image decoding in the way.
    private func solid(
        _ width: Int,
        _ height: Int,
        r: UInt8,
        g: UInt8,
        b: UInt8,
        a: UInt8 = 255
    ) -> RGBAImage {
        var pixels = [UInt8]()
        pixels.reserveCapacity(width * height * 4)
        for _ in 0 ..< (width * height) {
            pixels.append(contentsOf: [r, g, b, a])
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    @Test("identical images score 1.0 with no changed regions")
    func identical() {
        let image = solid(4, 4, r: 10, g: 20, b: 30)
        let result = ImageDiff.compare(image, image, tolerance: 0)
        #expect(result.similarity == 1.0)
        #expect(result.changedPixelCount == 0)
        #expect(result.changedRegions.isEmpty)
        #expect(result.sizeMismatch == nil)
    }

    @Test("a single changed pixel yields a 1x1 region and a known score")
    func singleChangedPixel() {
        let baseline = solid(2, 2, r: 0, g: 0, b: 0)
        var pixels = baseline.pixels
        // Pixel (x: 1, y: 0) → byte index (0 * 2 + 1) * 4 = 4.
        pixels[4] = 255
        pixels[5] = 255
        pixels[6] = 255
        let current = RGBAImage(width: 2, height: 2, pixels: pixels)

        let result = ImageDiff.compare(baseline, current, tolerance: 0)
        #expect(result.totalPixelCount == 4)
        #expect(result.changedPixelCount == 1)
        #expect(result.similarity == 0.75)
        #expect(result.changedRegions == [DiffRegion(x: 1, y: 0, width: 1, height: 1)])
    }

    @Test("fully differing images score 0 and the region spans the image")
    func fullyDifferent() {
        let black = solid(3, 3, r: 0, g: 0, b: 0)
        let white = solid(3, 3, r: 255, g: 255, b: 255)
        let result = ImageDiff.compare(black, white, tolerance: 0)
        #expect(result.similarity == 0.0)
        #expect(result.changedPixelCount == 9)
        #expect(result.changedRegions == [DiffRegion(x: 0, y: 0, width: 3, height: 3)])
    }

    @Test("sub-tolerance noise is ignored")
    func toleranceAbsorbsNoise() {
        let baseline = solid(2, 2, r: 100, g: 100, b: 100)
        var pixels = baseline.pixels
        pixels[0] = 105 // one channel off by 5, under the tolerance of 8
        let noisy = RGBAImage(width: 2, height: 2, pixels: pixels)

        let result = ImageDiff.compare(baseline, noisy, tolerance: 8)
        #expect(result.similarity == 1.0)
        #expect(result.changedPixelCount == 0)
        #expect(result.changedRegions.isEmpty)
    }

    @Test("a delta above tolerance still counts as changed")
    func aboveToleranceCounts() {
        let baseline = solid(1, 1, r: 100, g: 100, b: 100)
        var pixels = baseline.pixels
        pixels[0] = 109 // off by 9, over the tolerance of 8
        let current = RGBAImage(width: 1, height: 1, pixels: pixels)

        let result = ImageDiff.compare(baseline, current, tolerance: 8)
        #expect(result.changedPixelCount == 1)
        #expect(result.similarity == 0.0)
    }

    @Test("renderDiff: false scores without producing a diff image")
    func scoreOnlySkipsDiffImage() {
        let baseline = solid(2, 2, r: 0, g: 0, b: 0)
        var pixels = baseline.pixels
        pixels[4] = 255
        let current = RGBAImage(width: 2, height: 2, pixels: pixels)

        let result = ImageDiff.compare(baseline, current, tolerance: 0, renderDiff: false)
        #expect(result.changedPixelCount == 1)
        #expect(result.similarity == 0.75)
        #expect(result.changedRegions == [DiffRegion(x: 1, y: 0, width: 1, height: 1)])
        #expect(result.diffImage == nil)
    }

    @Test("out-of-range tolerance is clamped to 0...255")
    func toleranceIsClamped() {
        let black = solid(2, 2, r: 0, g: 0, b: 0)
        let white = solid(2, 2, r: 255, g: 255, b: 255)
        // Above 255 → clamped to 255, so a full-range change still counts as unchanged.
        #expect(ImageDiff.compare(black, white, tolerance: 999).similarity == 1.0)
        // Below 0 → clamped to 0, so any nonzero delta counts as changed.
        var pixels = black.pixels
        pixels[0] = 1
        let nudged = RGBAImage(width: 2, height: 2, pixels: pixels)
        #expect(ImageDiff.compare(black, nudged, tolerance: -5).changedPixelCount == 1)
    }

    @Test("dimension mismatch reports a size mismatch instead of comparing")
    func dimensionMismatch() {
        let small = solid(2, 2, r: 0, g: 0, b: 0)
        let big = solid(3, 3, r: 0, g: 0, b: 0)
        let result = ImageDiff.compare(small, big, tolerance: 0)
        #expect(result.sizeMismatch == SizeMismatch(
            baseline: PixelSize(width: 2, height: 2),
            current: PixelSize(width: 3, height: 3)
        ))
        #expect(result.similarity == 0.0)
        #expect(result.diffImage == nil)
    }

    @Test("PNG round-trip preserves pixels — decode and pixel-compare, never byte-compare")
    func pngRoundTripIsLossless() throws {
        let original = solid(5, 5, r: 12, g: 200, b: 77)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-diff-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try original.pngData().write(to: url)
        let reloaded = try RGBAImage(contentsOf: url)

        let result = ImageDiff.compare(original, reloaded, tolerance: 0)
        #expect(result.sizeMismatch == nil)
        #expect(result.similarity == 1.0)
    }
}
