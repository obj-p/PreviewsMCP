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
        try await assertConcurrentSendsPreserveFraming { input, output in
            SerializedStdioTransport(input: input, output: output)
        }
    }
}
