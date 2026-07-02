import Foundation
import os
@testable import PreviewsCLI
import Testing

/// Framing safety under the exact conditions that corrupt the SDK transport
/// (#320): a message larger than the pipe buffer backs up mid-write (EAGAIN
/// suspension) while another `send` arrives. The SDK's actor-isolated `send`
/// is re-entrant at that suspension, splicing the second message into the
/// first's bytes; `SerializedStdioTransport` chains sends so every
/// newline-delimited frame arrives contiguous and decodable.
@Suite("SerializedStdioTransport framing")
struct SerializedStdioTransportTests {
    @Test("concurrent sends under pipe backpressure never interleave frames")
    func concurrentSendsPreserveFraming() async throws {
        let inPipe = Pipe()
        let outPipe = Pipe()
        let transport = SerializedStdioTransport(
            input: .init(rawValue: inPipe.fileHandleForReading.fileDescriptor),
            output: .init(rawValue: outPipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()

        let big = Data(#"{"big":"\#(String(repeating: "a", count: 300_000))"}"#.utf8)
        let small = Data(#"{"small":1}"#.utf8)
        let expectedBytes = big.count + small.count + 2

        // Collect the transport's output on a raw thread: the reader must not
        // drain the pipe while the big send is still queuing, or the write
        // never backs up into the EAGAIN suspension this test exists to
        // exercise — so it waits before its first read.
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

        // Start the big send; give it time to fill the pipe and suspend in
        // the EAGAIN retry, then race the small send into that window.
        let bigSend = Task { try await transport.send(big) }
        try await Task.sleep(for: .milliseconds(150))
        let smallSend = Task { try await transport.send(small) }
        try await bigSend.value
        try await smallSend.value

        // Both sends returned, so all bytes are in the pipe; poll the reader's
        // buffer up to a deadline rather than blocking the cooperative pool.
        let deadline = ContinuousClock.now + .seconds(10)
        while collected.withLock({ $0.count }) < expectedBytes, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }

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
}
