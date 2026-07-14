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

        guard let deviceUDID = try await SimulatorTestDevices.udid(index: 3) else {
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
/// tags seen. `onConnected` runs once the first body bytes arrive (the
/// subscriber is registered by then) to drive a screen change so an IDR is
/// produced. Returns when every tag in `need` has been seen or `timeout`
/// elapses. Raw socket, not URLSession — see RawHTTP.stream (#350).
private func readAVCCTags(
    port: Int, need: Set<UInt8>, timeout: Duration,
    onConnected: @escaping @Sendable () async -> Void
) async throws -> Set<UInt8> {
    struct Parse {
        var buffer = [UInt8]()
        var offset = 0
        var seen = Set<UInt8>()
    }
    let state = OSAllocatedUnfairLock(initialState: Parse())
    let head = try await attributed("avcc-raw") {
        try await RawHTTP.stream(
            port: port, path: "/stream.avcc", deadline: timeout, onConnected: onConnected
        ) { chunk in
            state.withLock { parse in
                parse.buffer.append(contentsOf: chunk)
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
    }
    #expect(
        head.contains("Content-Type: application/octet-stream"),
        "avcc stream should be octet-stream"
    )
    return state.withLock { $0.seen }
}
