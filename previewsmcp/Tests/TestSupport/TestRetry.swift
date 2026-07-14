public enum TestRetry {
    public static func firstSuccess<Result>(
        maximumAttempts: Int,
        operation: (Int) async throws -> Result?
    ) async rethrows -> Result? {
        precondition(maximumAttempts > 0, "maximumAttempts must be positive")
        for attempt in 1 ... maximumAttempts {
            if let result = try await operation(attempt) {
                return result
            }
        }
        return nil
    }
}
