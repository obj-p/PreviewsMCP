import Foundation
import MCP
import Network
import os
@testable import PreviewsCLI
import System
import Testing

/// The UDS channel (rewrite stage 3): raw POSIX sockets carried by the same
/// `FramedTransport` the stdio channel uses. The interop test runs the SDK's
/// `NetworkTransport` as the dialing side because that is exactly the
/// stage-5→6 window: our listener serving a CLI still on the SDK transport.
@Suite("DaemonSocket channel")
struct DaemonSocketTests {
    @Test("framed transports complete a round trip over a real UDS socket")
    func roundTripOverSocket() async throws {
        let path = try makeSocketPath()
        defer { removeSocketDirectory(path) }
        let listener = try DaemonSocket.listen(at: path)
        defer { try? listener.close() }
        let clientSocket = try DaemonSocket.connect(to: path)
        defer { try? clientSocket.close() }
        let serverSocket = try await DaemonSocket.accept(on: listener)
        defer { try? serverSocket.close() }

        let serverEnd = FramedTransport(socket: serverSocket)
        let clientEnd = FramedTransport(socket: clientSocket)
        try await serverEnd.connect()
        try await clientEnd.connect()

        let request = Data(#"{"blob":"\#(String(repeating: "u", count: 500_000))"}"#.utf8)
        let reply = Data(#"{"ok":true}"#.utf8)
        let seen = OSAllocatedUnfairLock(initialState: (request: Data?.none, reply: Data?.none))
        let serverReader = Task {
            for try await message in await serverEnd.receive() {
                seen.withLock { $0.request = message }
                break
            }
        }
        let clientReader = Task {
            for try await message in await clientEnd.receive() {
                seen.withLock { $0.reply = message }
                break
            }
        }
        defer {
            serverReader.cancel()
            clientReader.cancel()
        }

        try await clientEnd.send(request)
        try await serverEnd.send(reply)
        let delivered = try await pollUntil(
            { seen.withLock { $0.request != nil && $0.reply != nil ? $0 : nil } },
            failure: "socket round trip never completed"
        )
        #expect(delivered.request == request)
        #expect(delivered.reply == reply)
        await clientEnd.disconnect()
        await serverEnd.disconnect()
    }

    @Test("the SDK Client and Server complete a tool call over the socket channel")
    func differentialSDKOverSocket() async throws {
        let path = try makeSocketPath()
        defer { removeSocketDirectory(path) }
        let listener = try DaemonSocket.listen(at: path)
        defer { try? listener.close() }
        let clientSocket = try DaemonSocket.connect(to: path)
        defer { try? clientSocket.close() }
        let serverSocket = try await DaemonSocket.accept(on: listener)
        defer { try? serverSocket.close() }

        let server = await makeEchoServer(named: "uds-differential")
        try await server.start(transport: FramedTransport(socket: serverSocket))

        let client = Client(name: "uds-differential", version: "1")
        _ = try await client.connect(transport: FramedTransport(socket: clientSocket))
        try await expectEchoProbe(client)

        await client.disconnect()
        await server.stop()
    }

    @Test("an SDK NetworkTransport client interoperates with the framed listener")
    func interopWithSDKNetworkTransportClient() async throws {
        let path = try makeSocketPath()
        defer { removeSocketDirectory(path) }
        let listener = try DaemonSocket.listen(at: path)
        defer { try? listener.close() }

        let server = await makeEchoServer(named: "uds-interop")
        let accepted = OSAllocatedUnfairLock(initialState: FileDescriptor?.none)
        let serving = Task {
            let serverSocket = try await DaemonSocket.accept(on: listener)
            accepted.withLock { $0 = serverSocket }
            try await server.start(transport: FramedTransport(socket: serverSocket))
        }
        defer {
            serving.cancel()
            if let socket = accepted.withLock({ $0 }) { try? socket.close() }
        }

        let connection = NWConnection(to: NWEndpoint.unix(path: path), using: .tcp)
        let client = Client(name: "uds-interop", version: "1")
        _ = try await client.connect(transport: daemonChannelTransport(connection: connection))
        try await expectEchoProbe(client)

        await client.disconnect()
        await server.stop()
    }

    @Test("a framed client interoperates with an SDK NetworkTransport server")
    func interopWithSDKNetworkTransportServer() async throws {
        // The other half of the staged cutover: an upgraded CLI dialing a
        // stale pre-cutover daemon must still complete the handshake, or
        // the version-mismatch respawn can never run.
        let path = try makeSocketPath()
        defer { removeSocketDirectory(path) }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let nwListener = try NWListener(using: params)
        let acceptedConnection = OSAllocatedUnfairLock(initialState: NWConnection?.none)
        nwListener.newConnectionHandler = { connection in
            acceptedConnection.withLock { $0 = connection }
        }
        try await awaitListenerReady(nwListener)
        defer { nwListener.cancel() }

        let clientSocket = try DaemonSocket.connect(to: path)
        defer { try? clientSocket.close() }
        let serverSide = try await pollUntil(
            { acceptedConnection.withLock { $0 } },
            failure: "NWListener never accepted the framed client"
        )
        let server = await makeEchoServer(named: "uds-interop-reverse")
        try await server.start(transport: daemonChannelTransport(connection: serverSide))

        let client = Client(name: "uds-interop-reverse", version: "1")
        _ = try await client.connect(transport: FramedTransport(socket: clientSocket))
        try await expectEchoProbe(client)

        await client.disconnect()
        await server.stop()
    }

    @Test("accept is cancellable while the listener is idle")
    func acceptIsCancellable() async throws {
        let path = try makeSocketPath()
        defer { removeSocketDirectory(path) }
        let listener = try DaemonSocket.listen(at: path)
        defer { try? listener.close() }

        let outcome = OSAllocatedUnfairLock(initialState: Result<Void, Swift.Error>?.none)
        let accepting = Task {
            do {
                _ = try await DaemonSocket.accept(on: listener)
                outcome.withLock { $0 = .success(()) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        accepting.cancel()

        let result = try await pollUntil(
            { outcome.withLock { $0 } },
            failure: "cancelled accept never returned"
        )
        guard case let .failure(error) = result else {
            Issue.record("accept returned a connection nobody dialed")
            return
        }
        #expect(error is CancellationError)
    }

    @Test("connecting to a missing socket path throws")
    func connectToMissingPathThrows() throws {
        let path = try makeSocketPath()
        defer { removeSocketDirectory(path) }
        #expect(throws: Errno.self) {
            _ = try DaemonSocket.connect(to: path)
        }
    }

    @Test("an over-long socket path is rejected up front")
    func pathTooLongThrows() {
        let path = "/tmp/" + String(repeating: "p", count: 200)
        #expect(throws: Errno(rawValue: ENAMETOOLONG)) {
            _ = try DaemonSocket.listen(at: path)
        }
    }

    private func makeSocketPath() throws -> String {
        let directory = "/tmp/pmcp-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true
        )
        return directory + "/daemon.sock"
    }

    private func removeSocketDirectory(_ socketPath: String) {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: directory)
    }
}
