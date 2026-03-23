import Foundation
import PreviewsCore

/// Orchestrates the full iOS preview pipeline:
/// boot simulator → install host app → compile dylib → launch → screenshot.
///
/// Communicates with the iOS host app over a TCP loopback socket (127.0.0.1).
/// See docs/communication-protocol.md for protocol details.
public actor IOSPreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public private(set) var previewIndex: Int
    public nonisolated let deviceUDID: String

    private let compiler: Compiler
    private let hostBuilder: IOSHostBuilder
    private let simulatorManager: SimulatorManager

    private var session: PreviewSession?
    public nonisolated let headless: Bool
    private let buildContext: BuildContext?
    private var traits: PreviewTraits
    public var currentTraits: PreviewTraits { traits }

    // TCP socket state
    private var listenFD: Int32 = -1
    private var connectedFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var readBuffer = Data()
    // Data-typed continuations for Sendable compliance across task boundaries
    private var pendingDataResponses: [String: CheckedContinuation<Data, Error>] = [:]

    public static let hostBundleID = "com.previewsmcp.host"

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        deviceUDID: String,
        compiler: Compiler,
        hostBuilder: IOSHostBuilder,
        simulatorManager: SimulatorManager,
        headless: Bool = true,
        buildContext: BuildContext? = nil,
        traits: PreviewTraits = PreviewTraits()
    ) {
        self.id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.deviceUDID = deviceUDID
        self.compiler = compiler
        self.hostBuilder = hostBuilder
        self.simulatorManager = simulatorManager
        self.headless = headless
        self.buildContext = buildContext
        self.traits = traits
    }

    // MARK: - Lifecycle

    /// Start the iOS preview: compile, boot sim, install host, launch, connect socket.
    /// Returns the PID of the launched host app.
    public func start() async throws -> Int {
        // 1. Compile preview dylib for iOS simulator
        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOS,
            buildContext: buildContext,
            traits: traits
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        // 2. Boot simulator and install host app.
        let appPath = try await hostBuilder.ensureHostApp()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                let device = try await simulatorManager.findDevice(udid: deviceUDID)
                if device.state != .booted {
                    try await simulatorManager.bootDevice(udid: deviceUDID)
                    try await Task.sleep(for: .seconds(5))
                }
                try await simulatorManager.installApp(udid: deviceUDID, appPath: appPath.path)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(3))
                }
            }
        }
        if let lastError { throw lastError }

        // 3. Open Simulator.app GUI if not headless
        if !headless {
            _ = try? await runAsync(
                "/usr/bin/open",
                arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", deviceUDID]
            )
        }

        // 4. Create TCP server on loopback, bind to ephemeral port
        let serverFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw IOSPreviewSessionError.socketCreateFailed
        }
        var reuse: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // ephemeral
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(serverFD)
            throw IOSPreviewSessionError.socketCreateFailed
        }
        guard Darwin.listen(serverFD, 1) == 0 else {
            Darwin.close(serverFD)
            throw IOSPreviewSessionError.socketCreateFailed
        }

        // Read the assigned port
        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverFD, sockPtr, &boundLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        listenFD = serverFD

        // 5. Launch host app with dylib path and port
        let pid = try await simulatorManager.launchApp(
            udid: deviceUDID,
            bundleID: Self.hostBundleID,
            arguments: [
                "--dylib", compileResult.dylibPath.path,
                "--port", String(port),
            ]
        )

        // 6. Accept connection from host app (up to 10 seconds)
        try await acceptConnection(timeout: .seconds(10))
        setupReadLoop()

        return pid
    }

    /// Close the socket connection and clean up resources.
    public func stop() {
        // Fail any pending responses
        for (_, continuation) in pendingDataResponses {
            continuation.resume(throwing: IOSPreviewSessionError.connectionLost)
        }
        pendingDataResponses.removeAll()

        // Cancel read source (its cancel handler closes connectedFD)
        if let source = readSource {
            source.cancel()
            readSource = nil
        } else if connectedFD >= 0 {
            Darwin.close(connectedFD)
        }
        connectedFD = -1

        if listenFD >= 0 {
            Darwin.close(listenFD)
            listenFD = -1
        }

        readBuffer.removeAll()
    }

    // MARK: - Communication

    /// Recompile the preview and signal the host app to reload via socket.
    /// Waits for reloadAck to ensure SwiftUI environment has propagated.
    public func reload() async throws {
        guard connectedFD >= 0 else {
            throw IOSPreviewSessionError.notStarted
        }

        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOS,
            buildContext: buildContext,
            traits: traits
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        let requestID = UUID().uuidString
        _ = try await sendAndAwait(
            ["type": "reload", "id": requestID, "dylibPath": compileResult.dylibPath.path],
            id: requestID,
            timeout: .seconds(5)
        )
    }

    /// Handle a source file change. Tries the literal fast path first;
    /// falls back to full recompile if structural changes are detected.
    @discardableResult
    public func handleSourceChange() async throws -> Bool {
        guard connectedFD >= 0 else {
            throw IOSPreviewSessionError.notStarted
        }

        let newSource = try String(contentsOf: sourceFile, encoding: .utf8)

        // Fast path: literal-only change
        if let currentSession = session,
            let changes = await currentSession.tryLiteralUpdate(newSource: newSource),
            !changes.isEmpty
        {
            let json = changes.map { change -> [String: Any] in
                var entry: [String: Any] = ["id": change.id]
                switch change.newValue {
                case .string(let s):
                    entry["type"] = "string"
                    entry["value"] = s
                case .integer(let n):
                    entry["type"] = "integer"
                    entry["value"] = n
                case .float(let d):
                    entry["type"] = "float"
                    entry["value"] = d
                case .boolean(let b):
                    entry["type"] = "boolean"
                    entry["value"] = b
                }
                return entry
            }
            sendMessage(["type": "literals", "changes": json])
            return true
        }

        // Slow path: structural change, full recompile
        try await reload()
        return false
    }

    /// Switch to a different preview index and recompile. Traits are preserved. @State is lost.
    /// Rolls back the index if compilation fails.
    public func switchPreview(to newIndex: Int) async throws {
        let oldIndex = self.previewIndex
        self.previewIndex = newIndex
        do {
            try await reload()
        } catch {
            self.previewIndex = oldIndex
            throw error
        }
    }

    /// Update traits and recompile. Signals the host app to reload. @State is lost.
    public func reconfigure(traits: PreviewTraits) async throws {
        self.traits = self.traits.merged(with: traits)
        try await reload()
    }

    /// Send a tap at the given point coordinates (in device points).
    public func sendTap(x: Double, y: Double) async throws {
        sendMessage(["type": "touch", "action": "tap", "x": x, "y": y])
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Send a swipe gesture from one point to another.
    public func sendSwipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        duration: Double = 0.3,
        steps: Int = 10
    ) async throws {
        sendMessage([
            "type": "touch",
            "action": "swipe",
            "fromX": fromX, "fromY": fromY,
            "toX": toX, "toY": toY,
            "duration": duration, "steps": steps,
        ])
        try await Task.sleep(for: .milliseconds(Int(duration * 1000) + 200))
    }

    /// Fetch the accessibility tree from the running preview.
    /// - Parameter filter: Filter mode: "all" (default), "interactable", or "labeled"
    public func fetchElements(filter: String = "all") async throws -> String {
        guard connectedFD >= 0 else {
            throw IOSPreviewSessionError.notStarted
        }

        let requestID = UUID().uuidString
        let response = try await sendAndAwait(
            ["type": "elements", "id": requestID, "filter": filter],
            id: requestID,
            timeout: .seconds(3)
        )

        guard let tree = response["tree"] as? [String: Any] else {
            throw IOSPreviewSessionError.socketResponseTimeout("elementsResponse")
        }

        // Apply server-side filtering if needed
        let resultTree: [String: Any]
        if filter != "all", let filtered = filterTree(tree, mode: filter) {
            resultTree = filtered
        } else {
            resultTree = tree
        }

        let data = try JSONSerialization.data(withJSONObject: resultTree)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Capture a screenshot of the simulator.
    public func screenshot(jpegQuality: Double = 0.85) async throws -> Data {
        return try await simulatorManager.screenshotData(udid: deviceUDID, jpegQuality: jpegQuality)
    }

    // MARK: - Socket internals

    /// Accept an incoming connection on the listen socket.
    private func acceptConnection(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Int32.self) { group in
            group.addTask { [listenFD] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                    let source = DispatchSource.makeReadSource(
                        fileDescriptor: listenFD, queue: .global())
                    source.setEventHandler {
                        source.cancel()
                        let clientFD = Darwin.accept(listenFD, nil, nil)
                        if clientFD >= 0 {
                            cont.resume(returning: clientFD)
                        } else {
                            cont.resume(throwing: IOSPreviewSessionError.socketAcceptFailed)
                        }
                    }
                    source.setCancelHandler {}
                    source.resume()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw IOSPreviewSessionError.socketAcceptTimeout
            }
            let fd = try await group.next()!
            group.cancelAll()
            self.connectedFD = fd
        }
    }

    /// Set up a read loop on the connected socket.
    private func setupReadLoop() {
        let fd = connectedFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0..<n])
                if let self {
                    Task { await self.processIncomingData(data) }
                }
            } else if n == 0 {
                // EOF — host app disconnected
                if let self {
                    Task { await self.handleDisconnect() }
                }
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        readSource = source
    }

    /// Process incoming data from the socket (actor-isolated).
    private func processIncomingData(_ data: Data) {
        readBuffer.append(data)

        // Split on newlines and process complete messages
        while let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(readBuffer[readBuffer.startIndex..<newlineIndex])
            readBuffer = Data(readBuffer[(newlineIndex + 1)...])

            // Parse just enough to extract the id for routing
            guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                let id = message["id"] as? String
            else {
                continue
            }

            // Resume the waiting continuation with raw Data (Sendable-safe)
            if let continuation = pendingDataResponses.removeValue(forKey: id) {
                continuation.resume(returning: lineData)
            }
        }
    }

    /// Handle host app disconnect.
    private func handleDisconnect() {
        connectedFD = -1
        for (_, continuation) in pendingDataResponses {
            continuation.resume(throwing: IOSPreviewSessionError.connectionLost)
        }
        pendingDataResponses.removeAll()
    }

    /// Send a JSON message over the socket (fire-and-forget).
    private func sendMessage(_ dict: [String: Any]) {
        guard connectedFD >= 0,
            var data = try? JSONSerialization.data(withJSONObject: dict)
        else { return }
        data.append(0x0A)  // newline delimiter
        let fd = connectedFD
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, base + offset, remaining)
                if n <= 0 { break }
                offset += n
                remaining -= n
            }
        }
    }

    /// Send a message and await a response with the matching id.
    private func sendAndAwait(
        _ message: [String: Any], id: String, timeout: Duration
    ) async throws -> [String: Any] {
        sendMessage(message)

        // Register continuation on the actor, then race response vs timeout
        let responseData: Data = try await withCheckedThrowingContinuation { cont in
            pendingDataResponses[id] = cont

            // Start a timeout task that will fail the continuation if no response arrives
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                // Only resume if still pending (response hasn't arrived yet)
                if let cont = await self.removePendingResponse(forKey: id) {
                    cont.resume(throwing: IOSPreviewSessionError.socketResponseTimeout(id))
                }
            }
        }

        guard let dict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw IOSPreviewSessionError.socketResponseTimeout(id)
        }
        return dict
    }

    /// Remove and return a pending response continuation (actor-isolated helper to prevent double-resume).
    private func removePendingResponse(forKey id: String) -> CheckedContinuation<Data, Error>? {
        pendingDataResponses.removeValue(forKey: id)
    }

    // MARK: - Accessibility tree filtering

    private func filterTree(_ node: [String: Any], mode: String) -> [String: Any]? {
        let children = node["children"] as? [[String: Any]]

        if children == nil || children!.isEmpty {
            return matchesFilter(node, mode: mode) ? node : nil
        }

        var filteredChildren: [[String: Any]] = []
        for child in children! {
            if let filtered = filterTree(child, mode: mode) {
                filteredChildren.append(filtered)
            }
        }

        guard !filteredChildren.isEmpty else { return nil }

        var result = node
        result["children"] = filteredChildren
        return result
    }

    private func matchesFilter(_ node: [String: Any], mode: String) -> Bool {
        switch mode {
        case "interactable":
            guard let traits = node["traits"] as? [String] else { return false }
            let interactableTraits: Set<String> = ["button", "link", "adjustable", "searchField"]
            return traits.contains(where: { interactableTraits.contains($0) })
        case "labeled":
            if let label = node["label"] as? String, !label.isEmpty { return true }
            if let value = node["value"] as? String, !value.isEmpty { return true }
            if let identifier = node["identifier"] as? String, !identifier.isEmpty { return true }
            return false
        default:
            return true
        }
    }
}

public enum IOSPreviewSessionError: Error, LocalizedError, CustomStringConvertible {
    case notStarted
    case socketCreateFailed
    case socketAcceptFailed
    case socketAcceptTimeout
    case socketResponseTimeout(String)
    case connectionLost

    public var description: String {
        switch self {
        case .notStarted: return "iOS preview session has not been started"
        case .socketCreateFailed: return "Failed to create TCP server socket"
        case .socketAcceptFailed: return "Failed to accept connection from host app"
        case .socketAcceptTimeout: return "Timed out waiting for host app to connect"
        case .socketResponseTimeout(let id): return "Timed out waiting for response (id: \(id))"
        case .connectionLost: return "Connection to host app lost"
        }
    }

    public var errorDescription: String? { description }
}
