import Foundation
import Testing

@testable import PreviewsCore

@Suite("KeyframeSelector")
struct KeyframeSelectorTests {

    // MARK: - Helpers

    /// Generate a diff array of `count` values, all set to `value`.
    private func uniformDiffs(count: Int, value: Double) -> [Double] {
        [Double](repeating: value, count: count)
    }

    /// Generate a diff array simulating an ease-out animation:
    /// high diff at the start, decaying exponentially.
    private func easeOutDiffs(count: Int, peak: Double = 0.8, decay: Double = 0.85) -> [Double] {
        (0..<count).map { i in peak * pow(decay, Double(i)) }
    }

    /// Generate a diff array with a single spike at `spikeIndex`.
    private func spikeDiffs(count: Int, spikeIndex: Int, spikeValue: Double = 0.8) -> [Double] {
        var diffs = [Double](repeating: 0.01, count: count)
        diffs[spikeIndex] = spikeValue
        return diffs
    }

    // MARK: - Tests

    @Test("No motion — all diffs below threshold")
    func noMotion() {
        let diffs = uniformDiffs(count: 90, value: 0.01)  // 3s at 30fps
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        #expect(result.selectedIndices.isEmpty)
        #expect(result.motionStartFrame == nil)
        #expect(result.motionEndFrame == nil)
    }

    @Test("All motion — diffs always above threshold, never settles")
    func allMotion() {
        let diffs = uniformDiffs(count: 90, value: 0.5)
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        // Motion detected from start, never settles → uses full range
        #expect(result.motionStartFrame != nil)
        #expect(result.selectedIndices.count <= 6)
        #expect(result.selectedIndices.count >= 2)  // at least first+last
        // First and last of motion window must be included
        if let start = result.motionStartFrame, let end = result.motionEndFrame {
            #expect(result.selectedIndices.contains(start))
            #expect(result.selectedIndices.contains(end))
        }
    }

    @Test("Single spike — selects around the spike")
    func singleSpike() {
        let diffs = spikeDiffs(count: 90, spikeIndex: 45)
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        #expect(result.motionStartFrame == 45)
        // The spike is a single frame, so motion window is narrow
        #expect(result.selectedIndices.contains(45))
    }

    @Test("Ease-out decay — first and last frames of motion window included")
    func easeOutDecay() {
        let diffs = easeOutDiffs(count: 90, peak: 0.8, decay: 0.85)
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        #expect(result.motionStartFrame != nil)
        #expect(result.motionEndFrame != nil)
        if let start = result.motionStartFrame, let end = result.motionEndFrame {
            #expect(result.selectedIndices.contains(start))
            #expect(result.selectedIndices.contains(end))
        }
    }

    @Test("Min gap is respected — no two frames closer than minGapMs")
    func minGapRespected() {
        // High diffs on every frame, forcing the selector to skip some
        let diffs = uniformDiffs(count: 90, value: 0.5)
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 12, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        let sorted = result.selectedIndices.sorted()
        let minGapFrames = Int(ceil(Double(80) / 1000.0 * Double(30)))  // ~3 frames at 30fps
        for i in 1..<sorted.count {
            #expect(sorted[i] - sorted[i - 1] >= minGapFrames)
        }
    }

    @Test("Frame count budget — fewer candidates than budget fills with next-highest diffs")
    func budgetUnderflow() {
        // Sustained motion window with only 2 big spikes, asking for 6.
        // The motion window spans [10, 50] because diffs stay above stillThreshold.
        var diffs = uniformDiffs(count: 90, value: 0.03)  // above stillThreshold (0.02)
        diffs[10] = 0.5  // spike — above motionThreshold
        diffs[40] = 0.5  // spike — above motionThreshold
        // Set frames after 50 to below stillThreshold so motion window ends
        for i in 51..<90 { diffs[i] = 0.01 }
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        // Both spikes should be selected, plus forced endpoints
        #expect(result.selectedIndices.contains(10))
        #expect(result.selectedIndices.contains(40))
        #expect(result.motionStartFrame == 10)
    }

    @Test("Frame count budget — more candidates than budget prefers highest diffs")
    func budgetOverflow() {
        // Many frames cross the threshold, we only want 4
        let diffs = easeOutDiffs(count: 90, peak: 0.8, decay: 0.95)
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 4, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        #expect(result.selectedIndices.count <= 4)
    }

    @Test("Selected indices are sorted")
    func sortedOutput() {
        let diffs = easeOutDiffs(count: 90)
        let result = KeyframeSelector.select(
            diffs: diffs, frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        #expect(result.selectedIndices == result.selectedIndices.sorted())
    }

    @Test("Empty diffs returns no selection")
    func emptyDiffs() {
        let result = KeyframeSelector.select(
            diffs: [], frameCount: 6, minGapMs: 80, fps: 30,
            motionThreshold: 0.05, stillThreshold: 0.02
        )
        #expect(result.selectedIndices.isEmpty)
    }
}
