import AppKit
import CoreGraphics
import Foundation
import Vision

/// Vision-framework-based OCR over a captured framebuffer image. Used
/// to click UI elements by text rather than by pixel coordinate —
/// makes SA scripts survive Apple's per-version UI layout changes.
///
/// Coordinate semantics:
/// - Input: any image file (PNG/JPEG/...) at any resolution.
/// - Vision returns bounding boxes normalized to `[0, 1]` with origin
///   bottom-left.
/// - We translate to the caller-supplied framebuffer size with origin
///   top-left, so click coordinates feed directly into
///   `RFBClient.leftClick(x:y:)`.
public enum FramebufferOCR {
    public struct Observation: Sendable, Equatable {
        public let text: String
        /// Bounding box in framebuffer pixels, top-left origin —
        /// directly usable as RFB pointer coords.
        public let boundingBox: CGRect
        public var center: CGPoint {
            CGPoint(x: boundingBox.midX, y: boundingBox.midY)
        }
    }

    /// Run text recognition on the image at `imageURL`. Returns all
    /// recognized strings paired with their framebuffer-coord boxes.
    public static func recognize(
        imageURL: URL,
        framebufferSize: CGSize
    ) throws -> [Observation] {
        guard let nsImage = NSImage(contentsOf: imageURL) else {
            throw VMError("OCR: could not load image at \(imageURL.path)")
        }
        var rect = NSRect(origin: .zero, size: nsImage.size)
        guard let cgImage = nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw VMError("OCR: could not get CGImage from \(imageURL.path)")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false // SA strings are formal, no benefit from autocorrect
        // English is the language we target SA in, but Welcome cycles
        // through languages — accept whatever Vision finds and let
        // `find(target:)` match on text. Empty array = all supported.
        request.recognitionLanguages = []

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw VMError("OCR: VNRecognizeTextRequest failed", underlying: error)
        }

        let results = request.results ?? []
        return results.compactMap { obs -> Observation? in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox // normalized, bottom-left origin

            // Translate to top-left origin in framebuffer pixels.
            let fbX = box.minX * framebufferSize.width
            let fbWidth = box.width * framebufferSize.width
            let fbHeight = box.height * framebufferSize.height
            // Bottom-left → top-left: y_new = (1 - y_bottom) - height
            let fbY = (1.0 - box.minY - box.height) * framebufferSize.height
            return Observation(
                text: candidate.string,
                boundingBox: CGRect(x: fbX, y: fbY, width: fbWidth, height: fbHeight)
            )
        }
    }

    /// Find an observation whose text matches `target`. Strategy:
    /// 1. If any observation matches `target` exactly (case-insensitive),
    ///    return the one nearest the framebuffer center.
    /// 2. Otherwise fall back to substring matches, again preferring
    ///    the center-most.
    ///
    /// The exact-first ordering avoids the trap where a short target
    /// like "Agree" is consumed by a longer observation like
    /// "Disagree" — same with "Skip" / "Don't Skip". When the SA
    /// surface has both buttons on a confirmation dialog, the exact
    /// match is what we want.
    public static func find(
        _ target: String,
        in observations: [Observation],
        caseInsensitive: Bool = true,
        framebufferSize: CGSize? = nil
    ) -> Observation? {
        let needle = caseInsensitive ? target.lowercased() : target
        let normalize: (String) -> String = caseInsensitive
            ? { $0.lowercased() }
            : { $0 }

        let exact = observations.filter { normalize($0.text) == needle }
        if !exact.isEmpty {
            return pickCenterMost(exact, framebufferSize: framebufferSize)
        }
        let substrings = observations.filter {
            normalize($0.text).contains(needle)
        }
        return pickCenterMost(substrings, framebufferSize: framebufferSize)
    }

    private static func pickCenterMost(
        _ candidates: [Observation], framebufferSize: CGSize?
    ) -> Observation? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1, let size = framebufferSize else {
            return candidates.first
        }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        return candidates.min { distance($0.center, center) < distance($1.center, center) }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }
}
