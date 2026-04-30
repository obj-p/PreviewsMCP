import CoreGraphics
import Foundation

/// Computes Structural Similarity Index (SSIM) between two images.
///
/// Both images are downsampled to 128×128 grayscale before comparison.
/// Uses the canonical Wang et al. formulation with 8×8 sliding window.
///
/// Reference: Z. Wang, A.C. Bovik, H.R. Sheikh, E.P. Simoncelli,
/// "Image Quality Assessment: From Error Visibility to Structural Similarity,"
/// IEEE Transactions on Image Processing, 2004.
public enum FrameDiff {

    /// Compare two images and return their SSIM (0.0 = completely different, 1.0 = identical).
    public static func ssim(_ a: CGImage, _ b: CGImage) -> Double {
        let size = 128
        let pixelsA = downsampleToGrayscale(a, size: size)
        let pixelsB = downsampleToGrayscale(b, size: size)
        return computeSSIM(pixelsA, pixelsB, width: size, height: size)
    }

    // MARK: - Internal

    /// Downsample a CGImage to `size×size` grayscale, returning pixel values as [Double] in 0...255.
    static func downsampleToGrayscale(_ image: CGImage, size: Int) -> [Double] {
        let bytesPerRow = size
        var grayscale = [UInt8](repeating: 0, count: size * size)
        guard
            let context = CGContext(
                data: &grayscale,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return [Double](repeating: 0, count: size * size)
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return grayscale.map { Double($0) }
    }

    /// Compute mean SSIM over 8×8 non-overlapping windows.
    ///
    /// SSIM(x,y) = (2·μx·μy + C1)(2·σxy + C2) / ((μx² + μy² + C1)(σx² + σy² + C2))
    /// where C1 = (K1·L)², C2 = (K2·L)², L = 255, K1 = 0.01, K2 = 0.03
    private static func computeSSIM(
        _ a: [Double], _ b: [Double],
        width: Int, height: Int
    ) -> Double {
        let windowSize = 8
        let l: Double = 255.0
        let k1: Double = 0.01
        let k2: Double = 0.03
        let c1 = (k1 * l) * (k1 * l)
        let c2 = (k2 * l) * (k2 * l)

        var ssimSum: Double = 0
        var windowCount = 0

        let stepsX = width / windowSize
        let stepsY = height / windowSize

        for wy in 0..<stepsY {
            for wx in 0..<stepsX {
                let startX = wx * windowSize
                let startY = wy * windowSize
                let n = Double(windowSize * windowSize)

                var sumA: Double = 0
                var sumB: Double = 0
                var sumA2: Double = 0
                var sumB2: Double = 0
                var sumAB: Double = 0

                for dy in 0..<windowSize {
                    for dx in 0..<windowSize {
                        let idx = (startY + dy) * width + (startX + dx)
                        let pa = a[idx]
                        let pb = b[idx]
                        sumA += pa
                        sumB += pb
                        sumA2 += pa * pa
                        sumB2 += pb * pb
                        sumAB += pa * pb
                    }
                }

                let muA = sumA / n
                let muB = sumB / n
                let sigmaA2 = sumA2 / n - muA * muA
                let sigmaB2 = sumB2 / n - muB * muB
                let sigmaAB = sumAB / n - muA * muB

                let numerator = (2.0 * muA * muB + c1) * (2.0 * sigmaAB + c2)
                let denominator = (muA * muA + muB * muB + c1) * (sigmaA2 + sigmaB2 + c2)

                ssimSum += numerator / denominator
                windowCount += 1
            }
        }

        guard windowCount > 0 else { return 0 }
        return ssimSum / Double(windowCount)
    }
}
