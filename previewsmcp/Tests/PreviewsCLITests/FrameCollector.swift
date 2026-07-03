import Foundation
import MCP
import os

/// Drains a transport's `receive()` stream into a queryable JSON-RPC frame
/// store. Shared by the server- and client-side characterization harnesses;
/// `onFrame` lets a harness react to frames as they arrive (the raw
/// responder's auto-answer).
final class FrameCollector: Sendable {
    private let frames = OSAllocatedUnfairLock(initialState: [Data]())
    private let reader: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    init(reading transport: InMemoryTransport, onFrame: (@Sendable (Data) async -> Void)? = nil) {
        let frames = frames
        let task = Task {
            do {
                for try await frame in await transport.receive() {
                    frames.withLock { $0.append(frame) }
                    await onFrame?(frame)
                }
            } catch {}
        }
        reader.withLock { $0 = task }
    }

    func stop() {
        reader.withLock { $0 }?.cancel()
    }

    func rawFrame(forID id: Int) -> Data? {
        frames.withLock { $0 }.first { Self.object($0)?["id"] as? Int == id }
    }

    func frame(forID id: Int) -> [String: Any]? {
        rawFrame(forID: id).flatMap(Self.object)
    }

    func frame(forStringID id: String) -> [String: Any]? {
        frames.withLock { $0 }.compactMap(Self.object).first { $0["id"] as? String == id }
    }

    func notification(method: String) -> [String: Any]? {
        frames.withLock { $0 }.compactMap(Self.object).first { $0["method"] as? String == method }
    }

    func sawMethod(_ method: String) -> Bool {
        notification(method: method) != nil
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
