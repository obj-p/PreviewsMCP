import PreviewsTestSupport
import Testing

struct TestRetryTests {
    @Test("returns the first successful attempt without extra work")
    func returnsFirstSuccess() async {
        var attempts: [Int] = []

        let result = await TestRetry.firstSuccess(maximumAttempts: 3) { attempt in
            attempts.append(attempt)
            return attempt == 2 ? "changed" : nil
        }

        #expect(result == "changed")
        #expect(attempts == [1, 2])
    }

    @Test("returns nil after exhausting the bounded attempts")
    func exhaustsAttempts() async {
        var attempts: [Int] = []

        let result: String? = await TestRetry.firstSuccess(maximumAttempts: 3) { attempt in
            attempts.append(attempt)
            return nil
        }

        #expect(result == nil)
        #expect(attempts == [1, 2, 3])
    }
}
