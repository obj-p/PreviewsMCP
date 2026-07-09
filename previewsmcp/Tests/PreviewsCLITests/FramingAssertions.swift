import Foundation
import MCP
import os
import System
import Testing

/// Shared repro for the #320 defect class: a frame larger than the pipe
/// buffer backs up mid-write (EAGAIN suspension) while another `send` races
/// into that window. A safe transport delivers both newline-delimited frames
/// contiguous and decodable.
func assertConcurrentSendsPreserveFraming(
    makeTransport: (FileDescriptor, FileDescriptor) -> some Transport
) async throws {
    let inPipe = Pipe()
    let outPipe = Pipe()
    let transport = makeTransport(
        FileDescriptor(rawValue: inPipe.fileHandleForReading.fileDescriptor),
        FileDescriptor(rawValue: outPipe.fileHandleForWriting.fileDescriptor)
    )
    try await transport.connect()

    let big = Data(#"{"big":"\#(String(repeating: "a", count: 300_000))"}"#.utf8)
    let small = Data(#"{"small":1}"#.utf8)
    let expectedBytes = big.count + small.count + 2

    // Collect the transport's output on a raw thread: the reader must not
    // drain the pipe while the big send is still queuing, or the write
    // never backs up into the EAGAIN suspension this assertion exists to
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

    try await pollUntil(
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
