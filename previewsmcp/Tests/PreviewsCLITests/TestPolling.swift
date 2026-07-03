import Testing

/// Poll `value` every 25ms until it returns non-nil or `deadline` elapses;
/// on expiry, record `failure` and throw so the caller stops instead of
/// asserting against absent data.
func pollUntil<T>(
    _ value: () -> T?,
    failure: Comment,
    deadline: Duration = .seconds(10)
) async throws -> T {
    let clock = ContinuousClock()
    let limit = clock.now + deadline
    while clock.now < limit {
        if let found = value() { return found }
        try await Task.sleep(for: .milliseconds(25))
    }
    Issue.record(failure)
    throw CancellationError()
}
