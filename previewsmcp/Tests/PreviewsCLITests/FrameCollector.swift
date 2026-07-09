import Foundation
import MCP
import os

/// Drains a transport's `receive()` stream into a queryable JSON-RPC frame
/// store. Shared by the server- and client-side characterization harnesses;
/// `onFrame` lets a harness react to frames as they arrive (the raw
/// responder's auto-answer). Queries re-parse the small frame store on each
/// call; caching parses would force @unchecked Sendable for microseconds.
final class FrameCollector: Sendable {
    private let frames: OSAllocatedUnfairLock<[Data]>
    private let reader: Task<Void, Never>

    init(reading transport: InMemoryTransport, onFrame: (@Sendable (Data) async -> Void)? = nil) {
        let store = OSAllocatedUnfairLock(initialState: [Data]())
        frames = store
        reader = Task {
            do {
                for try await frame in await transport.receive() {
                    store.withLock { $0.append(frame) }
                    await onFrame?(frame)
                }
            } catch {}
        }
    }

    func stop() {
        reader.cancel()
    }

    func rawFrame(forID id: Int) -> Data? {
        frames.withLock { $0 }.first { Self.object($0)?["id"] as? Int == id }
    }

    func frame<ID: Equatable>(forID id: ID) -> [String: Any]? {
        frames.withLock { $0 }.compactMap(Self.object).first { $0["id"] as? ID == id }
    }

    func notification(method: String) -> [String: Any]? {
        frames.withLock { $0 }.compactMap(Self.object).first { $0["method"] as? String == method }
    }

    func sawMethod(_ method: String) -> Bool {
        notification(method: method) != nil
    }

    func countMethod(_ method: String) -> Int {
        frames.withLock { $0 }.compactMap(Self.object)
            .count { $0["method"] as? String == method }
    }

    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
