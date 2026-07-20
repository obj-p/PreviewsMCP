import Foundation

/// Run blocking work on a GCD queue instead of a cooperative-pool
/// thread. The JIT render/setup entries are synchronous FFI calls that
/// would otherwise pin their executor for the render's duration — which
/// starves same-executor tasks like the phase clock's ticker and, under
/// concurrent sessions, the pool itself (docs/phase-error-protocol.md).
private let blockingWorkQueue = DispatchQueue(
    label: "previewsmcp.blocking-work",
    attributes: .concurrent
)

public func offCooperativePool<T: Sendable>(
    _ work: @escaping @Sendable () -> T
) async -> T {
    await withCheckedContinuation { continuation in
        blockingWorkQueue.async { continuation.resume(returning: work()) }
    }
}

public func offCooperativePool<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        blockingWorkQueue.async { continuation.resume(with: Result(catching: work)) }
    }
}
