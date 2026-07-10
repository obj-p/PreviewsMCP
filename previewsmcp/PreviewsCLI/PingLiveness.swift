import Foundation
import MCP
import PreviewsCore

/// Missed-pong liveness policy for one side of an MCP connection. No field
/// defaults on purpose: the channel owns its policy, so every construction
/// site states its values (`DaemonListener` for the daemon's dead-client
/// detection, `DaemonClient.openClient` for the CLI's wedged-daemon
/// detection).
struct PingLiveness {
    var interval: Duration
    var missedPongLimit: Int
}

/// The shared ping loop both `PreviewsMCPServer` and `PreviewsMCPClient`
/// run: ping the peer on an interval, and disconnect the transport after
/// `missedPongLimit` consecutive intervals with no inbound traffic of ANY
/// kind (limit × interval of continuous silence — the bound the docs
/// state). The conforming actor's receive loop is the ground truth — it
/// resets `missedPongs` on every inbound frame, so a pong, a response, or
/// a notification all count as life.
protocol LivenessPinging: Actor {
    var missedPongs: Int { get set }
}

extension LivenessPinging {
    func pingLoop(
        on transport: any Transport, _ config: PingLiveness, peer: String
    ) async {
        // One frame for the loop's lifetime: pongs are never correlated by
        // id (any inbound frame resets the count), and both servers'
        // token-keyed in-flight tracking is pinned safe under repeated ids.
        guard let frame = try? MCPWire.encode(Ping.request()) else { return }
        while true {
            do {
                try await Task.sleep(for: config.interval)
            } catch {
                return
            }
            missedPongs += 1
            if missedPongs >= config.missedPongLimit {
                Log.info(
                    "declaring the \(peer) dead: no traffic in \(missedPongs) ping intervals"
                )
                await transport.disconnect()
                return
            }
            // Fire-and-forget: a ping that queues behind a frame wedged in
            // the transport's send chain (a peer that stopped draining)
            // must not park THIS loop — the missed-pong check is the whole
            // point in exactly that wedge class. A stuck or failed send
            // simply never resets the counter, and the limit tears the
            // connection down; disconnect cancels any queued ping sends.
            Task {
                try? await transport.send(frame)
            }
        }
    }
}
