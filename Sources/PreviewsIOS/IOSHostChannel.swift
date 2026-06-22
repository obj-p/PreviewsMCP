import Darwin
import Foundation
import PreviewsCore

/// An in-app JIT executor failure the host reported over its `jitError`
/// breadcrumb. `stage` is `connect` (the EPC socket never connected) or
/// `executor` (the ORC server failed to start after connecting); `code` is the
/// host-side return value when one is available.
public struct IOSHostJITError: Sendable, Equatable {
    public let stage: String
    public let code: Int?
}

/// TCP loopback transport between `IOSPreviewSession` and the iOS host
/// app. Owns all socket state (listen FD, connected FD, read source,
/// pending response continuations) and the line-delimited JSON protocol
/// used to drive reload / setTraits / fetchElements / touch from the
/// daemon side.
///
/// Lifecycle:
/// 1. `bindAndListen()` creates the server socket on an ephemeral
///    127.0.0.1 port and returns the assigned port. Caller passes the
///    port to the launching host app.
/// 2. `awaitConnect(timeout:)` waits up to `timeout` for the host app
///    to connect, then starts the read loop. After this returns,
///    `send` / `sendAndAwait` are usable.
/// 3. `send(_:)` and `sendAndAwait(_:id:timeout:)` push messages over
///    the socket. `sendAndAwait` registers a continuation keyed by
///    `id` and resolves it when a response with the matching `id`
///    arrives, or fails on timeout. The same `removeValue(forKey:)` is
///    used by the response and timeout paths so a continuation is
///    resumed exactly once.
/// 4. `close()` cancels the read source, fails any outstanding
///    continuations with `connectionLost`, and clears all FDs. Idempotent.
///
/// Errors thrown match the existing `IOSPreviewSessionError` cases —
/// callers' error handling on `IOSPreviewSession.start()` etc. is
/// preserved.
public actor IOSHostChannel {
    private var listenFD: Int32 = -1
    private var connectedFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    /// Data-typed continuations for Sendable compliance across task boundaries.
    private var pendingDataResponses: [String: CheckedContinuation<Data, Error>] = [:]

    /// Latest resident-memory reading (bytes) pushed by the host app's `memory`
    /// message. Zero until the first report arrives or after a disconnect.
    private var latestRSSBytes: UInt64 = 0
    public var latestRSS: UInt64 { latestRSSBytes }

    /// Latest `applicationState` the host app reported over its `lifecycle`
    /// message (`active` / `inactive` / `background`). Nil until the first
    /// breadcrumb arrives or after a disconnect. Used as the flash detector:
    /// a shell-hosted agent must never report `active`.
    private var latestApplicationStateValue: String?
    public var latestApplicationState: String? { latestApplicationStateValue }

    /// Last in-app JIT executor failure the host reported over its `jitError`
    /// message. Set when `connectLoopback`/`previewsmcp_ios_executor_start` fail
    /// inside the agent — a host-side fault the daemon would otherwise see only
    /// as a generic `acceptJIT` timeout or a confusing downstream link error.
    /// Sticky across disconnect so the start flow can enrich its thrown error.
    private var latestJITErrorValue: IOSHostJITError?
    public var latestJITError: IOSHostJITError? { latestJITErrorValue }

    /// Invoked once when the host app disconnects unexpectedly (EOF or read
    /// error), never on an intentional `close()`. Lets the session respawn a
    /// dead agent. See issue #253.
    private var onDisconnect: (@Sendable () async -> Void)?

    public init() {}

    /// Register the unexpected-disconnect callback. Replaces any prior one.
    public func setOnDisconnect(_ callback: @escaping @Sendable () async -> Void) {
        onDisconnect = callback
    }

    /// Whether the channel has an established connection to the host
    /// app. Used by callers to early-fail with `notStarted` before
    /// invoking transport methods.
    public var isConnected: Bool { connectedFD >= 0 }

    // MARK: - Lifecycle

    /// Bind a TCP server socket to 127.0.0.1 on an ephemeral port and
    /// start listening. Returns the assigned port.
    public func bindAndListen() throws -> Int {
        let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw IOSPreviewSessionError.socketCreateFailed
        }
        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFD)
            throw IOSPreviewSessionError.socketCreateFailed
        }
        guard Darwin.listen(serverFD, 1) == 0 else {
            Darwin.close(serverFD)
            throw IOSPreviewSessionError.socketCreateFailed
        }

        // Read the assigned port
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverFD, sockPtr, &boundLen)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(serverFD)
            throw IOSPreviewSessionError.socketCreateFailed
        }
        listenFD = serverFD
        return Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    /// Wait for the host app to connect (up to `timeout`), then start
    /// the read loop. After this returns, `send` and `sendAndAwait`
    /// are usable.
    public func awaitConnect(timeout: Duration) async throws {
        try await acceptConnection(timeout: timeout)
        setupReadLoop()
    }

    /// Cancel the read source, fail outstanding response continuations
    /// with `connectionLost`, and close all FDs. Idempotent.
    public func close() {
        // Fail any pending responses
        for (_, continuation) in pendingDataResponses {
            continuation.resume(throwing: IOSPreviewSessionError.connectionLost)
        }
        pendingDataResponses.removeAll()

        // Cancel read source (its cancel handler closes connectedFD)
        if let source = readSource {
            source.cancel()
            readSource = nil
        } else if connectedFD >= 0 {
            Darwin.close(connectedFD)
        }
        connectedFD = -1

        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }

        readBuffer.removeAll()
    }

    // MARK: - Send

    /// Send a JSON message over the socket (fire-and-forget).
    /// Newline-delimited. No-op if not connected.
    /// `sending` lets callers pass a `[String: Any]` literal across the
    /// actor boundary — the channel consumes it (serializes to bytes,
    /// drops the dict) and the caller releases its reference.
    public func send(_ dict: sending [String: Any]) {
        guard connectedFD >= 0,
            var data = try? JSONSerialization.data(withJSONObject: dict)
        else { return }
        data.append(0x0A)  // newline delimiter
        let fd = connectedFD
        var writeFailed = false
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, base + offset, remaining)
                if n <= 0 {
                    writeFailed = true
                    break
                }
                offset += n
                remaining -= n
            }
        }
        if writeFailed {
            handleDisconnect()
        }
    }

    /// Send a message and await a response with the matching `id`,
    /// returning the raw response bytes. Races the response against
    /// `timeout`; both the response path (`processIncomingData`) and
    /// the timeout path use `removeValue(forKey:)` to ensure exactly
    /// one resumption.
    ///
    /// Returns `Data` rather than a decoded dictionary because
    /// `[String: Any]` is not `Sendable` and crossing actor isolation
    /// back to the caller would require `sending` semantics that the
    /// response path can't provide. Callers decode the returned bytes
    /// with `JSONSerialization` themselves.
    public func sendAndAwait(
        _ message: sending [String: Any], id: String, timeout: Duration
    ) async throws -> Data {
        // Fail eagerly if the peer has already disconnected. Without
        // this guard the call would register a continuation that no
        // response can resolve and only the `timeout` would unblock it.
        // The race is real: a caller can hit `sendAndAwait` after a
        // peer FIN but before the read-loop's dispatched
        // `handleDisconnect` Task has entered the actor.
        guard connectedFD >= 0 else {
            throw IOSPreviewSessionError.connectionLost
        }

        return try await withCheckedThrowingContinuation { cont in
            // Register the continuation BEFORE calling `send`. If `send`
            // detects a write failure, it invokes `handleDisconnect`
            // synchronously on this actor turn, which iterates
            // `pendingDataResponses` and resumes every entry with
            // `connectionLost`. With the registration in this order, a
            // write-failure-induced disconnect resolves THIS continuation
            // rather than leaving it stranded for the timeout to clean up.
            pendingDataResponses[id] = cont
            send(message)

            // Timeout task: if no response arrives, fail the continuation.
            // Uses removeValue to guarantee no double-resume with
            // processIncomingData / handleDisconnect.
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                if let cont = await self.removePendingResponse(forKey: id) {
                    cont.resume(throwing: IOSPreviewSessionError.socketResponseTimeout(id))
                }
            }
        }
    }

    // MARK: - Internals

    /// Accept an incoming connection on the listen socket.
    private func acceptConnection(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { [listenFD] in
                // The dispatch source is owned by the continuation closure
                // but must also be cancellable from the task-cancellation
                // handler when the timeout task throws. Without this path,
                // `withCheckedThrowingContinuation` ignores cancellation
                // and Task 1 stays suspended forever on the source — the
                // 10s timer throws, the group waits for Task 1 to
                // terminate, and the whole acceptConnection hangs until
                // some upstream kills the caller (see iOS CI regression
                // where a flaky host-app connection turned into a 20-min
                // step timeout instead of a 10s clean failure).
                let sourceBox = DispatchSourceBox()
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation {
                        (cont: CheckedContinuation<Int32, Error>) in
                        let source = DispatchSource.makeReadSource(
                            fileDescriptor: listenFD, queue: .global())
                        sourceBox.store(source)
                        var resumed = false
                        source.setEventHandler {
                            source.cancel()
                            guard !resumed else { return }
                            resumed = true
                            let clientFD = Darwin.accept(listenFD, nil, nil)
                            if clientFD >= 0 {
                                cont.resume(returning: clientFD)
                            } else {
                                cont.resume(throwing: IOSPreviewSessionError.socketAcceptFailed)
                            }
                        }
                        source.setCancelHandler {
                            guard !resumed else { return }
                            resumed = true
                            cont.resume(throwing: IOSPreviewSessionError.socketAcceptTimeout)
                        }
                        source.resume()
                    }
                } onCancel: {
                    sourceBox.cancel()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw IOSPreviewSessionError.socketAcceptTimeout
            }
            let fd = try await group.next()!
            group.cancelAll()
            self.connectedFD = fd
        }

        // Close listen socket after successful accept — no longer needed
        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }
    }

    /// Set up a read loop on the connected socket.
    private func setupReadLoop() {
        let fd = connectedFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                if let self {
                    Task { await self.processIncomingData(data) }
                }
            } else if n == 0 {
                // EOF — host app disconnected
                if let self {
                    Task { await self.handleDisconnect() }
                }
            } else {
                // read() error — treat as disconnect (ECONNRESET, etc.)
                let err = errno
                if err != EAGAIN && err != EWOULDBLOCK {
                    if let self {
                        Task { await self.handleDisconnect() }
                    }
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        readSource = source
    }

    /// Process incoming data from the socket (actor-isolated).
    private func processIncomingData(_ data: Data) {
        readBuffer.append(data)

        // Split on newlines and process complete messages
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(readBuffer[readBuffer.startIndex..<newlineIndex])
            readBuffer = Data(readBuffer[(newlineIndex + 1)...])

            guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }

            // Unsolicited memory report (no id) — record and move on.
            if message["type"] as? String == "memory", let rss = message["rss"] as? Int {
                latestRSSBytes = UInt64(max(0, rss))
                continue
            }

            // Unsolicited lifecycle breadcrumb (no id) — record and move on.
            if message["type"] as? String == "lifecycle", let state = message["state"] as? String {
                latestApplicationStateValue = state
                continue
            }

            // Unsolicited in-app JIT failure breadcrumb (no id) — record and move on.
            if message["type"] as? String == "jitError" {
                latestJITErrorValue = IOSHostJITError(
                    stage: message["stage"] as? String ?? "unknown",
                    code: message["code"] as? Int)
                continue
            }

            // Everything else is a response routed by id.
            guard let id = message["id"] as? String else {
                continue
            }

            // Resume the waiting continuation with raw Data (Sendable-safe)
            if let continuation = pendingDataResponses.removeValue(forKey: id) {
                continuation.resume(returning: lineData)
            }
        }
    }

    /// Handle host app disconnect. The read source keeps waking on EOF, so guard
    /// on `connectedFD` to run (and fire the callback) exactly once, and cancel
    /// the source to stop the wakeups.
    private func handleDisconnect() {
        guard connectedFD >= 0 else { return }
        connectedFD = -1
        latestRSSBytes = 0
        latestApplicationStateValue = nil
        if let source = readSource {
            source.cancel()
            readSource = nil
        }
        for (_, continuation) in pendingDataResponses {
            continuation.resume(throwing: IOSPreviewSessionError.connectionLost)
        }
        pendingDataResponses.removeAll()

        if let onDisconnect {
            Task { await onDisconnect() }
        }
    }

    /// Remove and return a pending response continuation (actor-isolated, prevents double-resume).
    private func removePendingResponse(forKey id: String) -> CheckedContinuation<Data, Error>? {
        pendingDataResponses.removeValue(forKey: id)
    }
}

/// Thread-safe holder for a `DispatchSourceRead` that needs to be
/// cancelled from outside the continuation that owns it. Used by
/// `acceptConnection` to bridge task-cancellation into dispatch-source
/// lifecycle — DispatchSource is not Sendable, so a plain closure
/// capture won't compile under Swift 6 strict concurrency.
private final class DispatchSourceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var source: DispatchSourceRead?

    func store(_ s: DispatchSourceRead) {
        lock.lock()
        defer { lock.unlock() }
        source = s
    }

    func cancel() {
        lock.lock()
        let s = source
        source = nil
        lock.unlock()
        s?.cancel()
    }
}
