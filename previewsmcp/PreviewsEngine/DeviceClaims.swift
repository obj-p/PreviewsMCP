import Foundation

/// Ownership ledger for simulator devices: one live preview session per
/// device, transferred in order (docs/state-invalidation.md, L01).
///
/// A claim moves `claiming` → `live` → gone. The window between
/// registering a claim and the session finishing its launch is long
/// (build + install + connect), so replacement must never tear down a
/// session that is still starting: a start that finds an existing claim
/// waits for it to leave `claiming`, then deterministically replaces the
/// live incumbent through the supplied `stopIncumbent` (which suppresses
/// the incumbent's death-watcher respawn via its own stop flag). Because
/// claiming claims are waited out, never preempted, a launching start
/// loses its claim only through its own failure-path `release`; the
/// false return of `confirmLive` is defense-in-depth for that window,
/// not a preemption signal.
///
/// Claims are keyed by an opaque `owner` token rather than the session ID
/// because the claim must exist before the session object does (the
/// expensive build runs between the two).
public actor DeviceClaims {
    private enum State: Equatable {
        case claiming
        case live(sessionID: String)
        case stopping
    }

    private struct Claim {
        let owner: String
        var state: State
    }

    private var claims: [String: Claim] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    /// Register `owner`'s claim on `device`, deterministically replacing a
    /// live incumbent. Returns the replaced session's ID, or nil if the
    /// device was free. Waits out claims that are mid-launch or mid-stop
    /// instead of tearing them down.
    public func claim(
        device: String, owner: String,
        stopIncumbent: @Sendable (String) async -> Void
    ) async -> String? {
        var replaced: String?
        while let existing = claims[device] {
            switch existing.state {
            case .claiming, .stopping:
                await waitForChange(on: device)
            case let .live(sessionID):
                claims[device]?.state = .stopping
                await stopIncumbent(sessionID)
                if claims[device]?.owner == existing.owner {
                    claims[device] = nil
                    notifyWaiters(on: device)
                }
                replaced = sessionID
            }
        }
        claims[device] = Claim(owner: owner, state: .claiming)
        return replaced
    }

    /// Promote `owner`'s claim to live once its session has started.
    /// Returns false when the claim is no longer held (the start was
    /// replaced while launching); the caller must tear its session down.
    public func confirmLive(device: String, owner: String, sessionID: String) -> Bool {
        guard claims[device]?.owner == owner else { return false }
        claims[device]?.state = .live(sessionID: sessionID)
        notifyWaiters(on: device)
        return true
    }

    /// Drop `owner`'s claim (session stopped, or its start failed).
    /// A claim owned by someone else is left alone.
    public func release(device: String, owner: String) {
        guard claims[device]?.owner == owner else { return }
        claims[device] = nil
        notifyWaiters(on: device)
    }

    /// Release the claim on `device` iff it is live for `sessionID`.
    /// Stop paths know only the session, not the owner token; the
    /// live-state guard means a replacement's fresh claim is never
    /// released by the replaced session's teardown.
    public func releaseLive(device: String, sessionID: String) {
        guard claims[device]?.state == .live(sessionID: sessionID) else { return }
        claims[device] = nil
        notifyWaiters(on: device)
    }

    private func waitForChange(on device: String) async {
        await withCheckedContinuation { continuation in
            waiters[device, default: []].append(continuation)
        }
    }

    private func notifyWaiters(on device: String) {
        let pending = waiters.removeValue(forKey: device) ?? []
        for waiter in pending {
            waiter.resume()
        }
    }
}
