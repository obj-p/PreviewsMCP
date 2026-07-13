import Foundation
import MCP
import os
import PreviewsIOS
import PreviewsTestSupport
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
        .timeLimit(.minutes(20))
    )
    func appServerEndToEnd() async throws {
        // Serialize the heavy iOS e2e suites against each other: three sims
        // booting and driving their displays at once starve the single host
        // GPU/window-server, so whichever loses the race flakes. One sim at a
        // time keeps each render/capture healthy.
        // The host lock extends that to sim-booting runs from other
        // checkouts (#336).
        let simLock = try await SimulatorTestLock.acquire()
        defer { simLock.release() }
        let lock = try await DaemonTestLock.acquire()
        defer { lock.release() }

        // Reset host-global CoreSimulator state once before the first iOS
        // preview boots — earlier Bazel targets leave it degraded (see
        // CoreSimulatorHygiene).
        await CoreSimulatorHygiene.resetOnce()

        guard let deviceUDID = await SimulatorTestDevices.udid(index: 3) else {
            if let failure = SimulatorTestDevices.missingDeviceFailure(
                index: 3, isCI: SimulatorTestDevices.isCI
            ) {
                Issue.record("\(failure)")
            }
            print("No dedicated test simulator for index 3 — skipping")
            return
        }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // preview_start pays first-boot + cold example build on a fresh
        // machine — see IOSMCPTests for the 600s rationale.
        let startResult = try await server.callToolResult(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "platform": .string("ios"),
                "deviceUDID": .string(deviceUDID),
                "headless": .bool(true),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ],
            timeout: .seconds(600)
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
        let (_, response) = try await attributed("control-post") {
            try await URLSession.shared.data(for: request)
        }
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
            _ = try? await attributed("avcc-keyframe-drag") {
                try await URLSession.shared.data(for: drag)
            }
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

/// Attribution for the #350 residual: `NSURLErrorDomain Code=-1 "(null)"` is
/// opaque at the top level, and the daemon side already logs healthy (#334),
/// so the failing layer must be pinned from the client. On error this prints
/// which await site threw plus the full `NSUnderlyingError`/CFStream cascade
/// (`_kCFStreamErrorDomainKey`/`CodeKey` carry the POSIX-level cause, e.g.
/// ECONNRESET vs ECONNREFUSED), then rethrows unchanged.
private func attributed<T>(
    _ site: String, _ body: () async throws -> T
) async rethrows -> T {
    do {
        return try await body()
    } catch {
        print("APPSERVER-ATTR site=\(site) \(errorChainDump(error))")
        throw error
    }
}

private func errorChainDump(_ error: Error) -> String {
    var lines = [String]()
    var current: NSError? = error as NSError
    var depth = 0
    while let nsError = current, depth < 6 {
        var line = "[\(depth)] domain=\(nsError.domain) code=\(nsError.code)"
        for key in ["_kCFStreamErrorDomainKey", "_kCFStreamErrorCodeKey"] {
            if let value = nsError.userInfo[key] {
                line += " \(key)=\(value)"
            }
        }
        if let url = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] {
            line += " url=\(url)"
        }
        lines.append(line)
        current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        depth += 1
    }
    return lines.joined(separator: " | ")
}

/// Read a bounded raw sample of the MJPEG response — status line, headers,
/// and `limit` body bytes — over a plain socket, NOT URLSession.
///
/// URLSession is unusable for sampling multipart/x-mixed-replace: its
/// multipart handling is timing-dependent, and once a full part sits
/// buffered before the consumer starts iterating (loopback burst + a
/// loaded machine), `AsyncBytes` either throws a bare NSURLError -1 or
/// delivers no bytes at all while the task reports no error — reproduced
/// deterministically outside the suite and root-caused as #350 (the ~1/9
/// "NSURLError-1 after first frame sent" flake; the daemon side was never
/// at fault). A raw read is timing-independent and asserts the actual
/// wire framing the browser viewer consumes.
private func readStreamSample(port: Int, limit: Int) async throws -> Data {
    let raw = try await attributed("mjpeg-raw") {
        try await RawHTTP.sample(
            port: port, path: "/stream.mjpeg",
            bodyLimit: limit, deadline: .seconds(10)
        )
    }
    #expect(
        raw.head.contains("Content-Type: multipart/x-mixed-replace"),
        "stream should be MJPEG multipart"
    )
    #expect(raw.body.range(of: Data("--frame\r\n".utf8)) != nil, "body should carry the part boundary")
    return raw.body
}

/// Read the length-prefixed `/stream.avcc` envelope stream and collect the chunk
/// tags seen. `onConnected` runs once the first byte arrives (the subscriber is
/// registered by then) to drive a screen change so an IDR is produced. Returns
/// when every tag in `need` has been seen or `timeout` elapses.
///
/// Fresh single-use ephemeral session: this helper abandons its response
/// mid-stream, and a shared session's connection pool can hand the dying
/// connection to a later request against the same host:port (#320).
private func readAVCCTags(
    port: Int, need: Set<UInt8>, timeout: Duration,
    onConnected: @escaping @Sendable () async -> Void
) async throws -> Set<UInt8> {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream.avcc")!)
    request.timeoutInterval = 25
    let (bytes, response) = try await attributed("avcc-connect") {
        try await session.bytes(for: request)
    }
    let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
    #expect(contentType.contains("application/octet-stream"), "avcc stream should be octet-stream")

    struct Parse {
        var buffer = [UInt8]()
        var offset = 0
        var seen = Set<UInt8>()
        var connected = false
    }
    let state = OSAllocatedUnfairLock(initialState: Parse())
    try await boundedRead("avcc-body", bytes, deadline: timeout) { byte in
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
///
/// Every abnormal exit (deadline in any of its three faces, or a genuine
/// stream error) prints an `APPSERVER-ATTR site=… exit=…` line with the
/// task's wire-level byte count and task error, so a #350 specimen is
/// attributed no matter which face it wears; the healthy limit-met exit
/// stays quiet.
private func boundedRead(
    _ site: String,
    _ bytes: URLSession.AsyncBytes,
    deadline: Duration,
    consume: @escaping @Sendable (UInt8) async -> Bool
) async throws {
    let reader = Task {
        for try await byte in bytes {
            guard await consume(byte) else { break }
        }
    }
    let resolvedBy = OSAllocatedUnfairLock<String?>(initialState: nil)
    func claimResume(_ who: String) -> Bool {
        resolvedBy.withLock { claimed in
            if claimed != nil { return false }
            claimed = who
            return true
        }
    }
    func taskDump() -> String {
        "wireBytes=\(bytes.task.countOfBytesReceived)"
            + " taskError=\(bytes.task.error.map(errorChainDump) ?? "nil")"
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
                if claimResume("reader") { cont.resume(with: result) }
            }
            Task {
                try? await Task.sleep(for: deadline)
                bytes.task.cancel()
                reader.cancel()
                try? await Task.sleep(for: .seconds(2))
                if claimResume("deadline") { cont.resume(returning: ()) }
            }
        }
        if resolvedBy.withLock({ $0 }) == "deadline" {
            print("APPSERVER-ATTR site=\(site) exit=deadline-abandoned \(taskDump())")
        }
    } catch is CancellationError {
        // Deadline: the caller inspects what arrived.
        print("APPSERVER-ATTR site=\(site) exit=deadline-cancellation \(taskDump())")
    } catch let error as URLError where error.code == .cancelled {
        // Same, surfaced through URLSession instead.
        print("APPSERVER-ATTR site=\(site) exit=deadline-urlcancelled \(taskDump())")
    } catch {
        print(
            "APPSERVER-ATTR site=\(site) exit=threw \(taskDump())"
                + " thrown: \(errorChainDump(error))"
        )
        throw error
    }
}
