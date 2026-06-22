import Darwin
import Foundation
import Testing

@testable import PreviewsIOS

/// Race-tests for the iOS agent-app socket channel. The most error-prone
/// piece of the original `IOSPreviewSession` socket layer was the
/// accept/disconnect cleanup: a peer that connects and immediately
/// closes can leave `pendingDataResponses` continuations dangling, leak
/// the `DispatchSourceRead`, or double-resume a continuation. These
/// tests exercise that path without spinning up a real iOS simulator.
@Suite("IOSAgentChannel")
struct IOSAgentChannelTests {

    @Test("sendAndAwait after peer disconnect fails fast with connectionLost")
    func disconnectBeforeSendFailsFast() async throws {
        let channel = IOSAgentChannel()
        defer { Task { await channel.close() } }

        let port = try await channel.bindAndListen()
        async let connect: Void = channel.awaitConnect(timeout: .seconds(5))
        let clientFD = try connectClient(port: port)
        try await connect

        Darwin.close(clientFD)

        // Wait up to 1s for the read loop to observe EOF.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline, await channel.isConnected {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!(await channel.isConnected), "channel should observe disconnect within 1s")

        // The early-check in `sendAndAwait` must catch the disconnected
        // state and fail without registering a continuation that only
        // the timeout could resolve.
        let start = Date()
        do {
            _ = try await channel.sendAndAwait(
                ["type": "ping", "id": "x"],
                id: "x",
                timeout: .seconds(5)
            )
            Issue.record("expected sendAndAwait to throw connectionLost")
        } catch IOSPreviewSessionError.connectionLost {
            // expected
        } catch {
            Issue.record("expected connectionLost, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "disconnect-before-send should fail in well under the 5s timeout")
    }

    @Test("pending sendAndAwait fails with connectionLost when peer disconnects mid-flight")
    func pendingFailsOnDisconnect() async throws {
        let channel = IOSAgentChannel()
        defer { Task { await channel.close() } }

        let port = try await channel.bindAndListen()
        async let connect: Void = channel.awaitConnect(timeout: .seconds(5))
        let clientFD = try connectClient(port: port)
        try await connect

        // Issue sendAndAwait in a background task with a long timeout.
        // Give the channel a moment to register the continuation, then
        // disconnect. The pending continuation must be resumed with
        // `connectionLost` via `handleDisconnect` — NOT via the timeout.
        let pending = Task {
            try await channel.sendAndAwait(
                ["type": "ping", "id": "x"],
                id: "x",
                timeout: .seconds(10)
            )
        }
        // 200ms is more than enough on local but adds CI cushion — a busy
        // GHA agent can take >50ms to schedule the actor entry.
        try await Task.sleep(for: .milliseconds(200))

        let start = Date()
        Darwin.close(clientFD)

        do {
            _ = try await pending.value
            Issue.record("expected pending sendAndAwait to throw connectionLost")
        } catch IOSPreviewSessionError.connectionLost {
            // expected
        } catch {
            Issue.record("expected connectionLost, got \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "pending continuation should be failed by disconnect well before the 10s timeout")
    }

    @Test("jitError breadcrumb from the host is recorded")
    func recordsJITError() async throws {
        let channel = IOSAgentChannel()
        defer { Task { await channel.close() } }

        let port = try await channel.bindAndListen()
        async let connect: Void = channel.awaitConnect(timeout: .seconds(5))
        let clientFD = try connectClient(port: port)
        try await connect

        let line = #"{"type":"jitError","stage":"connect","code":-1}"# + "\n"
        _ = line.withCString { Darwin.write(clientFD, $0, strlen($0)) }

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, await channel.latestJITError == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let recorded = await channel.latestJITError
        #expect(recorded?.stage == "connect")
        #expect(recorded?.code == -1)

        Darwin.close(clientFD)
    }

    @Test("onDisconnect fires once on peer death, never on close()")
    func onDisconnectFiresOnDeathNotClose() async throws {
        // Peer death (EOF) fires the callback exactly once.
        let channel = IOSAgentChannel()
        let deaths = DisconnectCounter()
        await channel.setOnDisconnect { await deaths.increment() }

        let port = try await channel.bindAndListen()
        async let connect: Void = channel.awaitConnect(timeout: .seconds(5))
        let clientFD = try connectClient(port: port)
        try await connect

        Darwin.close(clientFD)

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, await deaths.count == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Settle: a re-entrant read-loop EOF must not double-fire.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await deaths.count == 1, "peer death fires the callback exactly once")
        await channel.close()

        // Intentional close() must NOT fire the callback.
        let ch2 = IOSAgentChannel()
        let closes = DisconnectCounter()
        await ch2.setOnDisconnect { await closes.increment() }

        let port2 = try await ch2.bindAndListen()
        async let connect2: Void = ch2.awaitConnect(timeout: .seconds(5))
        let clientFD2 = try connectClient(port: port2)
        try await connect2

        await ch2.close()
        try await Task.sleep(for: .milliseconds(200))
        #expect(await closes.count == 0, "intentional close() does not fire the callback")
        Darwin.close(clientFD2)
    }

    @Test("close() is idempotent after a successful connect")
    func closeIsIdempotent() async throws {
        let channel = IOSAgentChannel()
        let port = try await channel.bindAndListen()
        async let connect: Void = channel.awaitConnect(timeout: .seconds(5))
        let clientFD = try connectClient(port: port)
        try await connect

        Darwin.close(clientFD)

        // Two close() calls in succession must not crash, double-cancel
        // the read source, or double-close any FD.
        await channel.close()
        await channel.close()

        let isConnected = await channel.isConnected
        #expect(!isConnected)
    }

    @Test("close() before any connect succeeds")
    func closeBeforeConnect() async throws {
        let channel = IOSAgentChannel()
        _ = try await channel.bindAndListen()
        await channel.close()
        // Second close() with everything already torn down must be a no-op.
        await channel.close()

        let isConnected = await channel.isConnected
        #expect(!isConnected)
    }

    @Test("close() before bindAndListen is a no-op")
    func closeWithoutBind() async {
        let channel = IOSAgentChannel()
        await channel.close()
        let isConnected = await channel.isConnected
        #expect(!isConnected)
    }

    // MARK: - Helpers

    /// Connect a TCP client socket to 127.0.0.1:port. Returns the
    /// client-side FD so the test can simulate a disconnect by closing
    /// it. Caller owns the FD.
    private func connectClient(port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IOSPreviewSessionError.socketCreateFailed
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw IOSPreviewSessionError.socketAcceptFailed
        }
        return fd
    }
}

/// Thread-safe disconnect-callback counter for the channel tests.
private actor DisconnectCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
