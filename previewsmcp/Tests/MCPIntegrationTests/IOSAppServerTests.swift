import Foundation
import MCP
import os
import PreviewsIOS
import Testing

/// Verifies the per-session app interface that the daemon hosts in-process:
/// `preview_start` returns its loopback port, `POST /control` drives the hosted
/// scene through IndigoHID, and `GET /stream.mjpeg` streams the shell composite.
/// Separate from the agent MCP/CLI path.
@Suite("iOS app server", .serialized)
struct IOSAppServerTests {
    private struct StartInfo: Decodable {
        let appServerPort: Int?
    }

    @Test(
        "daemon-hosted app server drives and streams the preview",
        .timeLimit(.minutes(20)),
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "boots a simulator + compiles a preview; local-only like fullIOSWorkflow"
        )
    )
    func appServerEndToEnd() async throws {
        // Serialize the heavy iOS e2e suites against each other: locally (these
        // are .disabled on CI) three sims booting and driving their displays at
        // once starve the single host GPU/window-server, so whichever loses the
        // race flakes. One sim at a time keeps each render/capture healthy.
        let lock = try await DaemonTestLock.acquire()
        defer { lock.release() }

        // Reset host-global CoreSimulator state once before the first iOS
        // preview boots — earlier Bazel targets leave it degraded (see
        // CoreSimulatorHygiene).
        await CoreSimulatorHygiene.resetOnce()

        guard let deviceUDID = try await IOSSimulatorPicker.pickUDID(index: 3) else {
            print("No iOS simulator at picker index 3 — skipping")
            return
        }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let startResult = try await server.callToolResult(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "platform": .string("ios"),
                "deviceUDID": .string(deviceUDID),
                "headless": .bool(true),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        #expect(startResult.isError != true, "iOS preview_start should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startResult.content)
        let info = try MCPTestServer.decodeStructured(StartInfo.self, from: startResult)
        guard let port = info.appServerPort else {
            Issue.record("preview_start did not return an app server port")
            return
        }
        let resultText = MCPTestServer.extractText(from: startResult.content)
        #expect(
            resultText.contains("http://127.0.0.1:\(port)/"),
            "preview_start result should surface the interactive viewer URL"
        )
        try await Task.sleep(for: .seconds(3))

        // Control: a drag over /control scrolls the list, proving the
        // daemon-hosted server forwards input to IndigoHID.
        let beforeDrag = try await server.snapshotBytes(sessionID: sessionID)
        var request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:\(port)/control")))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action":"drag","fromX":0.5,"fromY":0.7,"toX":0.5,"toY":0.3,"steps":12}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "control POST should return 200")
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeDrag, timeout: .seconds(10)
        )

        // Stream: the in-process capture serves a real JPEG over /stream.mjpeg.
        let sample = try await readStreamSample(port: port, limit: 20000)
        #expect(
            sample.range(of: Data([0xFF, 0xD8, 0xFF])) != nil,
            "stream should carry a real JPEG frame"
        )

        // H.264: /stream.avcc serves the avcC description (0x01) and an IDR
        // keyframe (0x02). The encoder produces frames on screen change and
        // arms a keyframe on connect, so we drive a scroll once connected.
        let tags = try await readAVCCTags(port: port, need: [0x01, 0x02], timeout: .seconds(20)) {
            var drag = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/control")!)
            drag.httpMethod = "POST"
            drag.setValue("application/json", forHTTPHeaderField: "Content-Type")
            drag.httpBody = Data(
                #"{"action":"drag","fromX":0.5,"fromY":0.3,"toX":0.5,"toY":0.7,"steps":12}"#.utf8
            )
            _ = try? await URLSession.shared.data(for: drag)
        }
        #expect(tags.contains(0x01), "avcc stream should carry an avcC description")
        #expect(tags.contains(0x02), "avcc stream should carry an H.264 keyframe")

        // A lossless PNG snapshot (quality 1.0) must come back as a real PNG
        // from the wired streamer pipeline, not the load-racing one-shot path.
        let pngResult = try await server.callToolResult(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID), "quality": .double(1.0)]
        )
        try MCPTestServer.assertValidImage(pngResult.content, expectedMimeType: "image/png")

        _ = try await server.callToolResult(
            name: "preview_stop", arguments: ["sessionID": .string(sessionID)]
        )
    }
}

/// Read a bounded sample of an MJPEG stream, asserting the multipart content
/// type. URLSession unwraps multipart/x-mixed-replace and delivers the JPEG
/// part bodies without the boundary.
///
/// Uses a fresh single-use session, NOT `URLSession.shared`: these helpers
/// abandon their response mid-body (the server is still streaming when the
/// sample completes), and a shared session's connection pool can hand the
/// dying connection to the next request against the same host:port — caught
/// live as `NSURLErrorDomain Code=-1` on the follow-up `/stream.avcc` request
/// ~50ms after a successful mjpeg sample (#320: daemon log showed the stream
/// healthy, first frame sent, no server-side error). A fresh session has an
/// empty pool, so nothing poisoned can be reused; `invalidateAndCancel()`
/// tears the abandoned connection down with the session.
private func readStreamSample(port: Int, limit: Int) async throws -> Data {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream.mjpeg")!)
    request.timeoutInterval = 15
    let (bytes, response) = try await session.bytes(for: request)
    let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
    #expect(contentType.contains("multipart/x-mixed-replace"), "stream should be MJPEG multipart")

    let buffer = OSAllocatedUnfairLock(initialState: Data())
    try await boundedRead(bytes, deadline: .seconds(10)) { byte in
        let count = buffer.withLock {
            $0.append(byte)
            return $0.count
        }
        return count < limit
    }
    return buffer.withLock { $0 }
}

/// Read the length-prefixed `/stream.avcc` envelope stream and collect the chunk
/// tags seen. `onConnected` runs once the first byte arrives (the subscriber is
/// registered by then) to drive a screen change so an IDR is produced. Returns
/// when every tag in `need` has been seen or `timeout` elapses.
///
/// Fresh single-use session for the same reason as `readStreamSample`.
private func readAVCCTags(
    port: Int, need: Set<UInt8>, timeout: Duration,
    onConnected: @escaping @Sendable () async -> Void
) async throws -> Set<UInt8> {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream.avcc")!)
    request.timeoutInterval = 25
    let (bytes, response) = try await session.bytes(for: request)
    let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
    #expect(contentType.contains("application/octet-stream"), "avcc stream should be octet-stream")

    struct Parse {
        var buffer = [UInt8]()
        var offset = 0
        var seen = Set<UInt8>()
        var connected = false
    }
    let state = OSAllocatedUnfairLock(initialState: Parse())
    try await boundedRead(bytes, deadline: timeout) { byte in
        let fireConnect = state.withLock { parse -> Bool in
            if parse.connected { return false }
            parse.connected = true
            return true
        }
        if fireConnect {
            await onConnected()
        }
        return state.withLock { parse in
            parse.buffer.append(byte)
            while parse.buffer.count - parse.offset >= 4 {
                let length =
                    Int(parse.buffer[parse.offset]) << 24 | Int(parse.buffer[parse.offset + 1]) << 16
                        | Int(parse.buffer[parse.offset + 2]) << 8 | Int(parse.buffer[parse.offset + 3])
                guard parse.buffer.count - parse.offset >= 4 + length else { break }
                parse.seen.insert(parse.buffer[parse.offset + 4])
                parse.offset += 4 + length
            }
            return !need.isSubset(of: parse.seen)
        }
    }
    return state.withLock { $0.seen }
}

/// Feed `bytes` to `consume` until it returns false or `deadline` elapses,
/// then return; rethrows genuine stream errors. The deadline must bound the
/// await itself, not just the loop body: when the app server drops the
/// connection without URLSession surfacing it (observed: server-side drop
/// right after headers → zero body bytes → socket gone, iterator never
/// resumes), an in-body deadline check is unreachable and the test hangs
/// holding DaemonTestLock until its `.timeLimit` — queued suites then blow
/// their own limits as collateral.
///
/// The outer await must never structurally depend on the reader resuming.
/// Two weaker designs were disproven by thread-sampling recurred wedges:
/// cooperative `Task.cancel()` does not resume an iterator parked inside
/// `AsyncBytes.Iterator.next()`, and even `bytes.task.cancel()` leaves the
/// continuation unresumed when the transfer is already dead underneath
/// (`reloadBufferAndNext()` parked with no completion left to deliver). So
/// the deadline path races the reader via a once-guarded continuation and,
/// after a short grace for the cancels to land, abandons it — leaking one
/// suspended task and its dead connection for the remaining test-process
/// lifetime, which is bounded and harmless. The caller's assertions on
/// whatever partial data arrived produce the attributable failure.
private func boundedRead(
    _ bytes: URLSession.AsyncBytes,
    deadline: Duration,
    consume: @escaping @Sendable (UInt8) async -> Bool
) async throws {
    let reader = Task {
        for try await byte in bytes {
            guard await consume(byte) else { break }
        }
    }
    let resumed = OSAllocatedUnfairLock(initialState: false)
    func claimResume() -> Bool {
        resumed.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
    do {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Task {
                let result: Result<Void, Error>
                do {
                    try await reader.value
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
                if claimResume() { cont.resume(with: result) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                bytes.task.cancel()
                reader.cancel()
                try? await Task.sleep(for: .seconds(2))
                if claimResume() { cont.resume(returning: ()) }
            }
        }
    } catch is CancellationError {
        // Deadline: the caller inspects what arrived.
    } catch let error as URLError where error.code == .cancelled {
        // Same, surfaced through URLSession instead.
    }
}
