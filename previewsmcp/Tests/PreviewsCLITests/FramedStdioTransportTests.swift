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
@Suite("FramedStdioTransport")
struct FramedStdioTransportTests {
    @Test("concurrent sends under pipe backpressure never interleave frames")
    func concurrentSendsPreserveFraming() async throws {
        try await assertConcurrentSendsPreserveFraming { input, output in
            FramedStdioTransport(input: input, output: output)
        }
    }

    @Test("a frame larger than the pipe buffer arrives intact")
    func largeFrameRoundTrip() async throws {
        let pipe = Pipe()
        let senderNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? senderNull.close() }
        let receiverNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? receiverNull.close() }
        let sender = FramedStdioTransport(
            input: senderNull,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        let receiver = FramedStdioTransport(
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
        let transport = FramedStdioTransport(input: input, output: output)
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
        let transport = FramedStdioTransport(
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
        let transport = FramedStdioTransport(
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
        #expect(error as? FramedStdioTransportError == .truncatedFinalFrame)
        await transport.disconnect()
        withExtendedLifetime(pipe) {}
    }

    @Test("a dead peer surfaces as EPIPE and poisons later sends, not SIGPIPE")
    func deadPeerPoisonsInsteadOfKilling() async throws {
        let pipe = Pipe()
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let transport = FramedStdioTransport(
            input: input,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()
        try pipe.fileHandleForReading.close()

        await #expect(throws: Errno.brokenPipe) {
            try await transport.send(Data(#"{"a":1}"#.utf8))
        }
        await #expect(throws: FramedStdioTransportError.poisoned) {
            try await transport.send(Data(#"{"b":2}"#.utf8))
        }
        await transport.disconnect()
        withExtendedLifetime(pipe) {}
    }

    @Test("send after disconnect throws instead of writing")
    func sendAfterDisconnectThrows() async throws {
        let devNull = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? devNull.close() }
        let transport = FramedStdioTransport(input: devNull, output: devNull)
        try await transport.connect()
        await transport.disconnect()

        await #expect(throws: FramedStdioTransportError.disconnected) {
            try await transport.send(Data(#"{"late":1}"#.utf8))
        }
    }

    @Test("disconnect cancels a send wedged on a full pipe")
    func disconnectCancelsWedgedSend() async throws {
        // Nobody drains the pipe, so a frame larger than its buffer parks
        // the send in the EAGAIN retry forever unless disconnect frees it.
        let pipe = Pipe()
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let transport = FramedStdioTransport(
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
        let serverTransport = FramedStdioTransport(
            input: .init(rawValue: clientToServer.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: serverToClient.fileHandleForWriting.fileDescriptor)
        )
        let clientTransport = FramedStdioTransport(
            input: .init(rawValue: serverToClient.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: clientToServer.fileHandleForWriting.fileDescriptor)
        )

        let server = Server(
            name: "framed-differential", version: "1",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(CallTool.self) { params in
            CallTool.Result(content: [.text("echo:\(params.name)")])
        }
        try await server.start(transport: serverTransport)

        let client = Client(name: "framed-differential", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let result = try await client.callToolStructured(name: "probe")
        guard case let .text(text)? = result.content.first else {
            Issue.record("unexpected content: \(result.content)")
            return
        }
        #expect(text == "echo:probe")

        await client.disconnect()
        await server.stop()
        withExtendedLifetime((clientToServer, serverToClient)) {}
    }

    /// Drains `receive()` on a child task and polls for how it ended.
    private func receiveStreamOutcome(
        of transport: FramedStdioTransport,
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
