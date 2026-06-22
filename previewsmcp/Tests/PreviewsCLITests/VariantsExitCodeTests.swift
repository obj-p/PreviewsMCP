import Testing

@testable import PreviewsCLI

/// Unit tests for `VariantsCommand.exitCode(successCount:failCount:)`.
/// The doc comment commits to three branches:
///   * 0 — all variants captured
///   * 1 — partial failure (≥1 success, ≥1 fail)
///   * 2 — total failure (every variant failed)
/// Forcing deterministic per-variant failures through the real daemon
/// is expensive, so pin the mapping directly.
@Suite("variants exitCode mapping")
struct VariantsExitCodeTests {

    @Test("all success → 0")
    func allSuccess() {
        #expect(VariantsCommand.exitCode(successCount: 3, failCount: 0) == 0)
    }

    @Test("partial failure → 1")
    func partialFailure() {
        #expect(VariantsCommand.exitCode(successCount: 2, failCount: 1) == 1)
        #expect(VariantsCommand.exitCode(successCount: 1, failCount: 2) == 1)
    }

    @Test("total failure → 2")
    func totalFailure() {
        #expect(VariantsCommand.exitCode(successCount: 0, failCount: 3) == 2)
        #expect(VariantsCommand.exitCode(successCount: 0, failCount: 1) == 2)
    }

    /// Defensive: zero/zero is not a real runtime state (local validation
    /// rejects zero variants), but the pure function should still behave.
    @Test("zero variants → 0")
    func zeroVariants() {
        #expect(VariantsCommand.exitCode(successCount: 0, failCount: 0) == 0)
    }
}
