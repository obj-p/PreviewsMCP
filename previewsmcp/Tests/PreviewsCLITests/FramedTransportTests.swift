import Foundation
import MCP
import os
@testable import PreviewsCLI
import System
import Testing

/// The in-house stdio transport must beat the SDK's on its known defect
/// classes: interleaved sends under backpressure, silent read-loop death,
/// prose on stdout (structurally impossible — the logger is hard-wired
/// no-op), SIGPIPE process death, and silently dropped truncated frames.
/// The differential test runs the real SDK Client and Server over two of
/// these transports, keeping the SDK as the independent protocol
/// implementation.
@Suite("FramedTransport")
struct FramedTransportTests {
    @Test("concurrent sends under pipe backpressure never interleave frames")
    func concurrentSendsPreserveFraming() async throws {
        try await assertConcurrentSendsPreserveFraming { input, output in
            FramedTransport(input: input, output: output)
        }
    }

    @Test("a frame larger than the pipe buffer arrives intact")
    func largeFrameRoundTrip() async throws {
        let pipe = Pipe()
        let senderNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? senderNull.close() }
        let receiverNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? receiverNull.close() }
        let sender = FramedTransport(
            input: senderNull,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        let receiver = FramedTransport(
            input: .init(rawValue: pipe.fileHandleForReading.fileDescriptor),
            output: receiverNull
        )
        try await sender.connect()
        try await receiver.connect()

        let payload = Data(#"{"blob":"\#(String(repeating: "x", count: 1_000_000))"}"#.utf8)
        let received = OSAllocatedUnfairLock(initialState: Data?.none)
        let collector = Task {
            for try await message in await receiver.receive() {
                received.withLock { $0 = message }
                break
            }
        }
        defer { collector.cancel() }

        try await sender.send(payload)
        let message = try await pollUntil(
            { received.withLock { $0 } },
            failure: "large frame never arrived"
        )
        #expect(message == payload)
        await sender.disconnect()
        await receiver.disconnect()
        withExtendedLifetime(pipe) {}
    }

    @Test("a real read error finishes the stream throwing, not silently")
    func readErrorPropagates() async throws {
        // A write-only input fails every read with EBADF, the errno the
        // SDK's loop would swallow silently. Closing a live fd mid-run
        // would race parallel tests: the number gets reused and the loop
        // reads someone else's descriptor.
        let input = try FileDescriptor.open("/dev/null", .writeOnly)
        defer { try? input.close() }
        let output = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? output.close() }
        let transport = FramedTransport(input: input, output: output)
        try await transport.connect()

        let result = try await receiveStreamOutcome(
            of: transport,
            failure: "stream neither finished nor threw on an unreadable input"
        )
        guard case .failure = result else {
            Issue.record("read error was swallowed: stream finished cleanly")
            return
        }
        await transport.disconnect()
    }

    @Test("peer EOF finishes the stream cleanly")
    func eofFinishesCleanly() async throws {
        let pipe = Pipe()
        let output = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? output.close() }
        let transport = FramedTransport(
            input: .init(rawValue: pipe.fileHandleForReading.fileDescriptor),
            output: output
        )
        try await transport.connect()
        try pipe.fileHandleForWriting.close()

        let result = try await receiveStreamOutcome(
            of: transport,
            failure: "stream never finished after peer EOF"
        )
        guard case .success = result else {
            Issue.record("EOF surfaced as an error: \(result)")
            return
        }
        await transport.disconnect()
        withExtendedLifetime(pipe) {}
    }

    @Test("EOF with a buffered partial frame finishes the stream throwing")
    func truncatedFinalFrameThrows() async throws {
        let pipe = Pipe()
        let output = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? output.close() }
        let transport = FramedTransport(
            input: .init(rawValue: pipe.fileHandleForReading.fileDescriptor),
            output: output
        )
        try await transport.connect()
        try pipe.fileHandleForWriting.write(contentsOf: Data(#"{"cut"#.utf8))
        try pipe.fileHandleForWriting.close()

        let result = try await receiveStreamOutcome(
            of: transport,
            failure: "stream never finished after a truncated EOF"
        )
        guard case let .failure(error) = result else {
            Issue.record("truncated final frame was silently dropped")
            return
        }
        #expect(error as? FramedTransportError == .truncatedFinalFrame)
        await transport.disconnect()
        withExtendedLifetime(pipe) {}
    }

    @Test("a dead peer surfaces as EPIPE and poisons later sends, not SIGPIPE")
    func deadPeerPoisonsInsteadOfKilling() async throws {
        let pipe = Pipe()
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let transport = FramedTransport(
            input: input,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()
        try pipe.fileHandleForReading.close()

        await #expect(throws: Errno.brokenPipe) {
            try await transport.send(Data(#"{"a":1}"#.utf8))
        }
        await #expect(throws: FramedTransportError.poisoned) {
            try await transport.send(Data(#"{"b":2}"#.utf8))
        }
        await transport.disconnect()
        withExtendedLifetime(pipe) {}
    }

    @Test("send after disconnect throws instead of writing")
    func sendAfterDisconnectThrows() async throws {
        let devNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? devNull.close() }
        let transport = FramedTransport(input: devNull, output: devNull)
        try await transport.connect()
        await transport.disconnect()

        await #expect(throws: FramedTransportError.disconnected) {
            try await transport.send(Data(#"{"late":1}"#.utf8))
        }
    }

    @Test("send before connect throws instead of blocking a raw fd")
    func sendBeforeConnectThrows() async throws {
        let devNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? devNull.close() }
        let transport = FramedTransport(input: devNull, output: devNull)

        await #expect(throws: FramedTransportError.notConnected) {
            try await transport.send(Data(#"{"early":1}"#.utf8))
        }
    }

    @Test("re-entrant disconnects share the quiescence rendezvous")
    func reentrantDisconnectWaits() async throws {
        let pipe = Pipe()
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let transport = FramedTransport(
            input: input,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()

        let outcome = OSAllocatedUnfairLock(initialState: Result<Void, Swift.Error>?.none)
        let wedged = Task {
            do {
                try await transport.send(Data(repeating: UInt8(ascii: "z"), count: 300_000))
                outcome.withLock { $0 = .success(()) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        defer { wedged.cancel() }
        try await Task.sleep(for: .milliseconds(200))

        async let first: Void = transport.disconnect()
        async let second: Void = transport.disconnect()
        _ = await (first, second)

        let result = try await pollUntil(
            { outcome.withLock { $0 } },
            failure: "wedged send survived concurrent disconnects"
        )
        guard case .failure = result else {
            Issue.record("send of an undrained frame reported success")
            return
        }
        withExtendedLifetime(pipe) {}
    }

    @Test("disconnect cancels a send wedged on a full pipe")
    func disconnectCancelsWedgedSend() async throws {
        // Nobody drains the pipe, so a frame larger than its buffer parks
        // the send in the EAGAIN retry forever unless disconnect frees it.
        let pipe = Pipe()
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let transport = FramedTransport(
            input: input,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()

        let outcome = OSAllocatedUnfairLock(initialState: Result<Void, Swift.Error>?.none)
        let wedged = Task {
            do {
                try await transport.send(Data(repeating: UInt8(ascii: "y"), count: 300_000))
                outcome.withLock { $0 = .success(()) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        defer { wedged.cancel() }

        try await Task.sleep(for: .milliseconds(200))
        await transport.disconnect()

        let result = try await pollUntil(
            { outcome.withLock { $0 } },
            failure: "wedged send was not released by disconnect"
        )
        guard case .failure = result else {
            Issue.record("send of an undrained frame reported success")
            return
        }
        withExtendedLifetime(pipe) {}
    }

    @Test("the SDK Client and Server complete a tool call over two framed transports")
    func differentialUnderSDKClientAndServer() async throws {
        // The independent-implementation cross-check: both protocol ends are
        // the SDK's, only the wire is ours.
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let serverTransport = FramedTransport(
            input: .init(rawValue: clientToServer.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: serverToClient.fileHandleForWriting.fileDescriptor)
        )
        let clientTransport = FramedTransport(
            input: .init(rawValue: serverToClient.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: clientToServer.fileHandleForWriting.fileDescriptor)
        )

        let server = await makeEchoServer(named: "framed-differential")
        try await server.start(transport: serverTransport)

        let client = Client(name: "framed-differential", version: "1")
        _ = try await client.connect(transport: clientTransport)
        try await expectEchoProbe(client)

        await client.disconnect()
        await server.stop()
        withExtendedLifetime((clientToServer, serverToClient)) {}
    }

    @Test("an owning transport closes its socket exactly once, after disconnect quiesces")
    func owningDisconnectClosesSocket() async throws {
        var raw = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &raw) == 0)
        let owned = FileDescriptor(rawValue: raw[0])
        let peer = FileDescriptor(rawValue: raw[1])
        defer { try? peer.close() }

        let transport = FramedTransport(owningSocket: owned)
        try await transport.connect()
        try await transport.send(Data("probe".utf8))
        await transport.disconnect()
        // Re-entrant disconnect shares the rendezvous: still exactly one
        // close, no EBADF trap on a recycled descriptor number.
        await transport.disconnect()

        // EOF on the peer is the observable proof the owned end closed —
        // no fd-number probing, which parallel tests could race via
        // descriptor reuse. Drain the sent frame first; EAGAIN means the
        // owned end is still open.
        try peer.setNonBlocking()
        var buffer = [UInt8](repeating: 0, count: 64)
        try await pollUntil(
            {
                while true {
                    do {
                        let count = try buffer.withUnsafeMutableBytes { try peer.read(into: $0) }
                        if count == 0 { return true }
                    } catch {
                        return false
                    }
                }
            },
            failure: "the peer never saw EOF from the owned socket"
        )
    }

    /// Drains `receive()` on a child task and polls for how it ended.
    private func receiveStreamOutcome(
        of transport: FramedTransport,
        failure: Comment
    ) async throws -> Result<Void, Swift.Error> {
        let outcome = OSAllocatedUnfairLock(initialState: Result<Void, Swift.Error>?.none)
        let consumer = Task {
            do {
                for try await _ in await transport.receive() {}
                outcome.withLock { $0 = .success(()) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        defer { consumer.cancel() }
        return try await pollUntil({ outcome.withLock { $0 } }, failure: failure)
    }
}
