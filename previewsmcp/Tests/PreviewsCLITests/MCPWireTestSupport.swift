import Foundation
import MCP
import Network
@testable import PreviewsCLI
import Testing

/// Shared fixtures for the wire-rewrite suites: the echo probe (an SDK
/// Server answering CallTool with `echo:<name>`, and the client-side
/// assertion) plus NWListener readiness for interop tests.
func makeEchoServer(named name: String) async -> Server {
    let server = Server(
        name: name, version: "1",
        capabilities: .init(tools: .init(listChanged: false))
    )
    await server.withMethodHandler(CallTool.self) { params in
        CallTool.Result(content: [.text("echo:\(params.name)")])
    }
    return server
}

func expectEchoProbe(_ client: Client) async throws {
    let result = try await client.callToolStructured(name: "probe")
    guard case let .text(text)? = result.content.first else {
        Issue.record("unexpected content: \(result.content)")
        return
    }
    #expect(text == "echo:probe")
}

/// A unique short directory under /tmp: sun_path caps UDS paths at 104
/// bytes, so bazel's deep TEST_TMPDIR is unusable for socket files.
func makeSocketPath() throws -> String {
    let directory = "/tmp/pmcp-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(
        atPath: directory, withIntermediateDirectories: true
    )
    return directory + "/daemon.sock"
}

func removeSocketDirectory(_ socketPath: String) {
    let directory = (socketPath as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: directory)
}

func awaitListenerReady(_ listener: NWListener) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                cont.resume()
                listener.stateUpdateHandler = nil
            case let .failed(error), let .waiting(error):
                cont.resume(throwing: error)
                listener.stateUpdateHandler = nil
            case .cancelled:
                cont.resume(throwing: CancellationError())
                listener.stateUpdateHandler = nil
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }
}
