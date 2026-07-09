import Foundation
import MCP
import os
@testable import PreviewsCLI
import System
import Testing

/// The in-house stdio transport must beat the SDK's on its three known
/// defect classes: interleaved sends under backpressure, silent read-loop
/// death, and prose on stdout (structurally impossible — the logger is
/// hard-wired no-op). The differential test runs the real SDK Client and
/// Server over two of these transports, keeping the SDK as the independent
/// protocol implementation.
@Suite("FramedStdioTransport")
struct FramedStdioTransportTests {
    @Test("concurrent sends under pipe backpressure never interleave frames")
    func concurrentSendsPreserveFraming() async throws {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let transport = FramedStdioTransport(
            input: .init(rawValue: inPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: outPipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()

        let big = Data(#"{"big":"\#(String(repeating: "a", count: 300_000))"}"#.utf8)
        let small = Data(#"{"small":1}"#.utf8)
        let expectedBytes = big.count + small.count + 2

        // Collect the transport's output on a raw thread: the reader must not
        // drain the pipe while the big send is still queuing, or the write
        // never backs up into the EAGAIN retry this test exists to exercise.
        let collected = OSAllocatedUnfairLock(initialState: Data())
        let readFD = outPipe.fileHandleForReading
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.4)
            while true {
                let chunk = readFD.availableData
                if chunk.isEmpty { break }
                let total = collected.withLock { data -> Int in
                    data.append(chunk)
                    return data.count
                }
                if total >= expectedBytes { break }
            }
        }

        let bigSend = Task { try await transport.send(big) }
        try await Task.sleep(for: .milliseconds(150))
        let smallSend = Task { try await transport.send(small) }
        try await bigSend.value
        try await smallSend.value

        _ = try await pollUntil(
            { collected.withLock { $0.count } >= expectedBytes },
            failure: "collector never saw both frames"
        )
        let lines = collected.withLock { $0 }.split(separator: UInt8(ascii: "\n"))
        #expect(lines.count == 2, "expected exactly 2 frames, got \(lines.count)")
        for line in lines {
            #expect(
                (try? JSONSerialization.jsonObject(with: Data(line))) != nil,
                "frame is not valid JSON — sends interleaved (first 80 bytes: \(String(decoding: line.prefix(80), as: UTF8.self)))"
            )
        }
        await transport.disconnect()
    }

    @Test("a frame larger than the pipe buffer arrives intact")
    func largeFrameRoundTrip() async throws {
        let pipe = Pipe()
        let sender = FramedStdioTransport(
            input: try FileDescriptor.open("/dev/null", .readWrite),
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        let receiver = FramedStdioTransport(
            input: .init(rawValue: pipe.fileHandleForReading.fileDescriptor),
            output: try FileDescriptor.open("/dev/null", .readWrite)
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
    }

    @Test("a real read error finishes the stream throwing, not silently")
    func readErrorPropagates() async throws {
        // A write-only input fails every read with EBADF, the errno the
        // SDK's loop would swallow silently. Closing a live fd mid-run
        // would race parallel tests: the number gets reused and the loop
        // reads someone else's descriptor.
        let transport = FramedStdioTransport(
            input: try FileDescriptor.open("/dev/null", .writeOnly),
            output: try FileDescriptor.open("/dev/null", .readWrite)
        )
        try await transport.connect()

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

        let result = try await pollUntil(
            { outcome.withLock { $0 } },
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
        let transport = FramedStdioTransport(
            input: .init(rawValue: pipe.fileHandleForReading.fileDescriptor),
            output: try FileDescriptor.open("/dev/null", .readWrite)
        )
        try await transport.connect()

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

        try pipe.fileHandleForWriting.close()

        let result = try await pollUntil(
            { outcome.withLock { $0 } },
            failure: "stream never finished after peer EOF"
        )
        guard case .success = result else {
            Issue.record("EOF surfaced as an error: \(result)")
            return
        }
        await transport.disconnect()
    }

    @Test("disconnect cancels a send wedged on a full pipe")
    func disconnectCancelsWedgedSend() async throws {
        // Nobody drains the pipe, so a frame larger than its buffer parks
        // the send in the EAGAIN retry forever unless disconnect frees it.
        let pipe = Pipe()
        let transport = FramedStdioTransport(
            input: try FileDescriptor.open("/dev/null", .readWrite),
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
    }
}
