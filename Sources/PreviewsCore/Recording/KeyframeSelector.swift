import Foundation

/// Selects keyframes from a sequence of per-frame SSIM diffs using
/// ffmpeg-style scene-detect semantics: pairwise threshold-gated emission
/// with a minimum gap between frames and forced endpoints.
public enum KeyframeSelector {

    /// Result of keyframe selection.
    public struct KeyframeSelection: Sendable {
        /// Index of the first frame where motion was detected, or nil if no motion.
        public let motionStartFrame: Int?
        /// Index of the last frame of the motion window, or nil if no motion.
        public let motionEndFrame: Int?
        /// Sorted indices of selected keyframes within the diff array.
        public let selectedIndices: [Int]
    }

    /// Select keyframes from a per-frame diff array.
    ///
    /// - Parameters:
    ///   - diffs: Per-frame SSIM difference from the previous frame (1.0 - SSIM).
    ///            Index 0 is the diff between frame 0 and frame 1.
    ///   - frameCount: Target number of keyframes to return.
    ///   - minGapMs: Minimum gap between selected frames in milliseconds.
    ///   - fps: Capture frame rate (used to convert minGapMs to frame count).
    ///   - motionThreshold: Diff value above which a frame is considered "in motion".
    ///   - stillThreshold: Diff value below which a frame is considered "settled".
    /// - Returns: A `KeyframeSelection` with the motion window and selected indices.
    public static func select(
        diffs: [Double],
        frameCount: Int,
        minGapMs: Int,
        fps: Int,
        motionThreshold: Double,
        stillThreshold: Double
    ) -> KeyframeSelection {
        guard !diffs.isEmpty else {
            return KeyframeSelection(
                motionStartFrame: nil, motionEndFrame: nil, selectedIndices: [])
        }

        // 1. Find motion window
        guard let motionStart = findMotionStart(diffs: diffs, threshold: motionThreshold) else {
            return KeyframeSelection(
                motionStartFrame: nil, motionEndFrame: nil, selectedIndices: [])
        }

        let motionEnd = findMotionEnd(
            diffs: diffs, startFrame: motionStart,
            stillThreshold: stillThreshold, settleFrames: settleFrameCount(fps: fps)
        )

        // 2. Select keyframes within the motion window
        let minGapFrames = max(1, Int(ceil(Double(minGapMs) / 1000.0 * Double(fps))))

        let selected = selectKeyframes(
            diffs: diffs,
            start: motionStart,
            end: motionEnd,
            frameCount: frameCount,
            minGapFrames: minGapFrames,
            motionThreshold: motionThreshold
        )

        return KeyframeSelection(
            motionStartFrame: motionStart,
            motionEndFrame: motionEnd,
            selectedIndices: selected
        )
    }

    // MARK: - Motion detection

    /// Find the first frame where diff exceeds the motion threshold.
    private static func findMotionStart(diffs: [Double], threshold: Double) -> Int? {
        diffs.firstIndex { $0 > threshold }
    }

    /// Find the end of the motion window: the first frame after `startFrame`
    /// where diff drops below `stillThreshold` for `settleFrames` consecutive frames.
    /// Falls back to the last diff index if motion never settles.
    private static func findMotionEnd(
        diffs: [Double], startFrame: Int,
        stillThreshold: Double, settleFrames: Int
    ) -> Int {
        var consecutiveStill = 0
        for i in (startFrame + 1)..<diffs.count {
            if diffs[i] < stillThreshold {
                consecutiveStill += 1
                if consecutiveStill >= settleFrames {
                    return i - settleFrames + 1
                }
            } else {
                consecutiveStill = 0
            }
        }
        return diffs.count - 1
    }

    /// Number of consecutive "still" frames needed to declare settle (~100ms).
    private static func settleFrameCount(fps: Int) -> Int {
        max(1, Int(ceil(Double(fps) * 0.1)))
    }

    // MARK: - Keyframe selection

    /// Select up to `frameCount` keyframes from the motion window,
    /// respecting `minGapFrames` between each pair.
    ///
    /// Strategy:
    /// 1. Collect all frames that cross `motionThreshold` (candidates).
    /// 2. Force-include first and last frames of the motion window.
    /// 3. Greedily pick candidates by descending diff, skipping any that
    ///    violate the min-gap constraint against already-selected frames.
    /// 4. If we have fewer than `frameCount`, fill with the highest-diff
    ///    non-candidate frames that respect the gap constraint.
    private static func selectKeyframes(
        diffs: [Double],
        start: Int,
        end: Int,
        frameCount: Int,
        minGapFrames: Int,
        motionThreshold: Double
    ) -> [Int] {
        guard start <= end else { return [start] }

        var selected = Set<Int>()

        // Force endpoints
        selected.insert(start)
        selected.insert(end)

        // All frames in the window, sorted by diff (descending)
        let windowFrames = (start...end).map { ($0, diffs[$0]) }
        let sortedByDiff = windowFrames.sorted { $0.1 > $1.1 }

        // Greedily pick frames by highest diff, respecting min-gap
        for (idx, diff) in sortedByDiff {
            if selected.count >= frameCount { break }
            if diff <= 0 { continue }
            if selected.contains(idx) { continue }
            if respectsGap(idx, against: selected, minGap: minGapFrames) {
                selected.insert(idx)
            }
        }

        return selected.sorted()
    }

    /// Check if `candidate` is at least `minGap` frames away from all frames in `selected`.
    private static func respectsGap(
        _ candidate: Int, against selected: Set<Int>, minGap: Int
    ) -> Bool {
        for s in selected {
            if abs(candidate - s) < minGap { return false }
        }
        return true
    }
}
