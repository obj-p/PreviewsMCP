import Foundation
import PreviewsIOS
import PreviewsTestSupport
import Testing

/// Verifies the PreviewAppServer MJPEG plumbing with a stub frame source. No
/// simulator: in production the real EventDrivenFrameSource runs in the daemon,
/// in-process with the session that owns the display.
@Suite("PreviewAppServer stream")
struct PreviewAppServerStreamTests {
    private struct StubFrameSource: FrameSource {
        let jpeg: Data
        func nextFrame() async -> Data? {
            jpeg
        }
    }

    private struct NoopInputSink: InputSink {
        func tap(x _: Double, y _: Double) {}
        func drag(fromX _: Double, fromY _: Double, toX _: Double, toY _: Double, steps _: Int) {}
    }

    @Test("GET /stream.mjpeg serves multipart JPEG frames")
    func streamServesFrames() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03, 0xFF, 0xD9])
        let appServer = PreviewAppServer(
            sink: NoopInputSink(),
            frameSource: StubFrameSource(jpeg: jpeg),
            streamIntervalMS: 10
        )
        let port = try await appServer.start()
        defer { appServer.stop() }

        let sample = try await readStreamSample(port: Int(port), limit: 256)
        #expect(sample.range(of: jpeg) != nil, "stream should carry the source JPEG bytes")
    }

    @Test("GET / serves the self-contained viewer page")
    func servesClientPage() async throws {
        let appServer = PreviewAppServer(sink: NoopInputSink())
        let port = try await appServer.start()
        defer { appServer.stop() }

        let (data, response) = try await URLSession.shared.data(
            from: try #require(URL(string: "http://127.0.0.1:\(port)/"))
        )
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect(http?.value(forHTTPHeaderField: "Content-Type")?.contains("text/html") == true)
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("/stream.avcc"), "page should wire the avcc stream")
        #expect(html.contains("VideoDecoder"), "page should use WebCodecs")
        #expect(html.contains("/stream.mjpeg"), "page should keep the MJPEG fallback")
    }
}

/// Read a bounded raw sample of the MJPEG response, asserting the multipart
/// content type and boundary on the wire. Raw socket, not URLSession — see
/// RawHTTP.sample (#350).
private func readStreamSample(port: Int, limit: Int) async throws -> Data {
    let raw = try await RawHTTP.sample(
        port: port, path: "/stream.mjpeg", bodyLimit: limit, deadline: .seconds(10)
    )
    #expect(
        raw.head.contains("Content-Type: multipart/x-mixed-replace"),
        "stream should be MJPEG multipart"
    )
    return raw.body
}
