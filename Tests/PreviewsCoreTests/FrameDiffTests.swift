import CoreGraphics
import Foundation
import Testing

@testable import PreviewsCore

@Suite("FrameDiff")
struct FrameDiffTests {

    // MARK: - Helpers

    /// Create a solid-color CGImage at the given dimensions.
    private func solidImage(
        width: Int = 64, height: Int = 64,
        r: UInt8, g: UInt8, b: UInt8
    ) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for i in 0..<(width * height) {
            pixels[i * bytesPerPixel + 0] = r
            pixels[i * bytesPerPixel + 1] = g
            pixels[i * bytesPerPixel + 2] = b
            pixels[i * bytesPerPixel + 3] = 255
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Create a horizontal gradient from black to white.
    private func gradientImage(width: Int = 128, height: Int = 128) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for y in 0..<height {
            for x in 0..<width {
                let val = UInt8(Double(x) / Double(width - 1) * 255)
                let i = (y * width + x) * bytesPerPixel
                pixels[i + 0] = val
                pixels[i + 1] = val
                pixels[i + 2] = val
                pixels[i + 3] = 255
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    /// Create a shifted gradient (offset by some pixels).
    private func shiftedGradientImage(
        width: Int = 128, height: Int = 128, shiftPixels: Int = 16
    ) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        for y in 0..<height {
            for x in 0..<width {
                let shifted = (x + shiftPixels) % width
                let val = UInt8(Double(shifted) / Double(width - 1) * 255)
                let i = (y * width + x) * bytesPerPixel
                pixels[i + 0] = val
                pixels[i + 1] = val
                pixels[i + 2] = val
                pixels[i + 3] = 255
            }
        }
        let data = Data(pixels)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }

    // MARK: - Tests

    @Test("Identical images produce SSIM ≈ 1.0")
    func identicalImages() {
        let img = solidImage(r: 128, g: 128, b: 128)
        let ssim = FrameDiff.ssim(img, img)
        #expect(abs(ssim - 1.0) < 1e-6)
    }

    @Test("Inverted images produce low SSIM")
    func invertedImages() {
        let white = solidImage(r: 255, g: 255, b: 255)
        let black = solidImage(r: 0, g: 0, b: 0)
        let ssim = FrameDiff.ssim(white, black)
        // Solid images have zero variance, so SSIM is based on luminance only.
        // For black vs white, SSIM should be very low.
        #expect(ssim < 0.1)
    }

    @Test("Slightly different images produce high but not perfect SSIM")
    func slightDifference() {
        let a = solidImage(r: 128, g: 128, b: 128)
        let b = solidImage(r: 140, g: 140, b: 140)
        let ssim = FrameDiff.ssim(a, b)
        #expect(ssim > 0.9)
        #expect(ssim < 1.0)
    }

    @Test("Gradient vs shifted gradient produces intermediate SSIM")
    func gradientShift() {
        let a = gradientImage()
        let b = shiftedGradientImage(shiftPixels: 16)
        let ssim = FrameDiff.ssim(a, b)
        // Should be measurably different but not completely dissimilar
        #expect(ssim > 0.3)
        #expect(ssim < 0.95)
    }

    @Test("SSIM is symmetric")
    func symmetry() {
        let a = solidImage(r: 100, g: 150, b: 200)
        let b = solidImage(r: 200, g: 100, b: 50)
        let ssimAB = FrameDiff.ssim(a, b)
        let ssimBA = FrameDiff.ssim(b, a)
        #expect(abs(ssimAB - ssimBA) < 1e-6)
    }

    @Test("Different sized images are handled by downsampling both to 128×128")
    func differentSizes() {
        let small = solidImage(width: 32, height: 32, r: 128, g: 128, b: 128)
        let large = solidImage(width: 400, height: 600, r: 128, g: 128, b: 128)
        let ssim = FrameDiff.ssim(small, large)
        // Same color → should be very high after downsampling
        #expect(ssim > 0.99)
    }
}
