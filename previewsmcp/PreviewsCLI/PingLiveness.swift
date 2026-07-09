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
/// `missedPongLimit` pings with no inbound traffic of ANY kind. The
/// conforming actor's receive loop is the ground truth — it resets
/// `missedPongs` on every inbound frame, so a pong, a response, or a
/// notification all count as life.
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
            if missedPongs >= config.missedPongLimit {
                Log.info("declaring the \(peer) dead: \(missedPongs) pings with no traffic")
                await transport.disconnect()
                return
            }
            missedPongs += 1
            do {
                try await transport.send(frame)
            } catch {
                Log.info("liveness ping send failed (\(error)); closing the connection")
                await transport.disconnect()
                return
            }
        }
    }
}
