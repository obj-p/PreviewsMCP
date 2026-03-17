import Foundation
import MCP
import PreviewsCore
import PreviewsMacOS
import PreviewsIOS

/// Tracks active iOS preview sessions and lazily creates shared iOS resources.
private actor IOSState {
    let simulatorManager = SimulatorManager()
    private var compiler: Compiler?
    private var hostBuilder: IOSHostBuilder?
    private var sessions: [String: IOSPreviewSession] = [:]
    private var fileWatchers: [String: FileWatcher] = [:]

    func getCompiler() async throws -> Compiler {
        if let c = compiler { return c }
        let c = try await Compiler(platform: .iOSSimulator)
        compiler = c
        return c
    }

    func getHostBuilder() async throws -> IOSHostBuilder {
        if let b = hostBuilder { return b }
        let b = try await IOSHostBuilder()
        hostBuilder = b
        return b
    }

    func addSession(_ session: IOSPreviewSession) {
        sessions[session.id] = session
    }

    func getSession(_ id: String) -> IOSPreviewSession? {
        sessions[id]
    }

    func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)
        fileWatchers[id]?.stop()
        fileWatchers.removeValue(forKey: id)
    }

    func setFileWatcher(_ id: String, _ watcher: FileWatcher) {
        fileWatchers[id] = watcher
    }

    func allSessionIDs() -> [String] {
        Array(sessions.keys)
    }
}

private let iosState = IOSState()

/// Configures and returns an MCP server with preview tools.
func configureMCPServer() async throws -> (Server, Compiler) {
    let compiler = try await Compiler()

    let server = Server(
        name: "previews-mcp",
        version: "0.2.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [
            Tool(
                name: "preview_list",
                description: "List #Preview blocks in a Swift source file",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filePath": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to a Swift source file"),
                        ]),
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: "preview_start",
                description: "Compile and launch a live SwiftUI preview. Returns a session ID. Supports macOS (default) and iOS simulator.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filePath": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to a Swift source file containing #Preview"),
                        ]),
                        "previewIndex": .object([
                            "type": .string("integer"),
                            "description": .string("0-based index of which #Preview to show (default: 0)"),
                        ]),
                        "platform": .object([
                            "type": .string("string"),
                            "description": .string("Target platform: 'macos' (default) or 'ios-simulator'"),
                        ]),
                        "deviceUDID": .object([
                            "type": .string("string"),
                            "description": .string("Simulator device UDID (for ios-simulator; auto-selects if omitted)"),
                        ]),
                        "headless": .object([
                            "type": .string("boolean"),
                            "description": .string("If false, opens Simulator.app GUI (iOS only, default: true)"),
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("Window width in points (macOS only, default: 400)"),
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("Window height in points (macOS only, default: 600)"),
                        ]),
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: "preview_snapshot",
                description: "Capture a screenshot of a running preview. Returns the image as PNG.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: "preview_stop",
                description: "Close a preview and clean up the session.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: "preview_elements",
                description: "Get the accessibility tree of an iOS simulator preview. Returns elements with labels, frames, and traits for targeted interaction.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start (iOS simulator only)"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: "preview_touch",
                description: "Send a touch event to an iOS simulator preview. Coordinates are in points.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start (iOS simulator only)"),
                        ]),
                        "x": .object([
                            "type": .string("number"),
                            "description": .string("X coordinate in points"),
                        ]),
                        "y": .object([
                            "type": .string("number"),
                            "description": .string("Y coordinate in points"),
                        ]),
                        "action": .object([
                            "type": .string("string"),
                            "description": .string("Touch action: 'tap' (default), 'touchDown', 'touchMove', 'touchUp'"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID"), .string("x"), .string("y")]),
                ])
            ),
            Tool(
                name: "simulator_list",
                description: "List available iOS simulator devices with their UDIDs and states.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "preview_list":
            return try await handlePreviewList(params: params)
        case "preview_start":
            return try await handlePreviewStart(params: params, macCompiler: compiler)
        case "preview_snapshot":
            return try await handlePreviewSnapshot(params: params)
        case "preview_stop":
            return try await handlePreviewStop(params: params)
        case "preview_elements":
            return try await handlePreviewElements(params: params)
        case "preview_touch":
            return try await handlePreviewTouch(params: params)
        case "simulator_list":
            return try await handleSimulatorList()
        default:
            return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
    }

    return (server, compiler)
}

// MARK: - Tool Handlers

private func handlePreviewList(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let filePath) = params.arguments?["filePath"] else {
        return CallTool.Result(content: [.text("Missing filePath parameter")], isError: true)
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
    }

    let previews = try PreviewParser.parse(fileAt: fileURL)

    if previews.isEmpty {
        return CallTool.Result(content: [.text("No #Preview blocks found in \(fileURL.lastPathComponent)")])
    }

    var lines: [String] = []
    for preview in previews {
        let name = preview.name ?? "Preview"
        lines.append("[\(preview.index)] \(name) (line \(preview.line))")
    }

    return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
}

private func handlePreviewStart(params: CallTool.Parameters, macCompiler: Compiler) async throws -> CallTool.Result {
    guard case .string(let filePath) = params.arguments?["filePath"] else {
        return CallTool.Result(content: [.text("Missing filePath parameter")], isError: true)
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
    }

    let previewIndex: Int
    if case .int(let n) = params.arguments?["previewIndex"] {
        previewIndex = n
    } else {
        previewIndex = 0
    }

    let platformStr: String
    if case .string(let p) = params.arguments?["platform"] {
        platformStr = p
    } else {
        platformStr = "macos"
    }

    // iOS simulator path
    if platformStr == "ios-simulator" {
        return try await handleIOSPreviewStart(
            fileURL: fileURL,
            previewIndex: previewIndex,
            params: params
        )
    }

    // macOS path (default)
    let width: Int
    if case .int(let n) = params.arguments?["width"] {
        width = n
    } else {
        width = 400
    }

    let height: Int
    if case .int(let n) = params.arguments?["height"] {
        height = n
    } else {
        height = 600
    }

    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: macCompiler
    )

    let compileResult = try await session.compile()
    let sessionID = session.id

    await MainActor.run {
        do {
            try App.host.loadPreview(
                sessionID: sessionID,
                dylibPath: compileResult.dylibPath,
                title: "Preview: \(fileURL.lastPathComponent)",
                size: NSSize(width: width, height: height)
            )
            App.host.watchFile(
                sessionID: sessionID,
                session: session,
                filePath: fileURL.path,
                compiler: macCompiler,
                previewIndex: previewIndex
            )
        } catch {
            fputs("MCP: Failed to load preview: \(error)\n", stderr)
        }
    }

    return CallTool.Result(content: [.text("macOS preview started. Session ID: \(sessionID). File is being watched for changes.")])
}

private func handleIOSPreviewStart(
    fileURL: URL,
    previewIndex: Int,
    params: CallTool.Parameters
) async throws -> CallTool.Result {
    // Resolve device UDID — use provided or auto-select
    let deviceUDID: String
    if case .string(let udid) = params.arguments?["deviceUDID"] {
        deviceUDID = udid
    } else {
        // Auto-select: prefer booted device, else first available
        let manager = iosState.simulatorManager
        do {
            let booted = try await manager.findBootedDevice()
            deviceUDID = booted.udid
        } catch {
            let devices = try await manager.listDevices()
            guard let first = devices.first(where: { $0.isAvailable }) else {
                return CallTool.Result(content: [.text("No available iOS simulator devices found")], isError: true)
            }
            deviceUDID = first.udid
        }
    }

    let iosCompiler = try await iosState.getCompiler()
    let hostBuilder = try await iosState.getHostBuilder()
    let simulatorManager = iosState.simulatorManager

    let headless: Bool
    if case .bool(let h) = params.arguments?["headless"] {
        headless = h
    } else {
        headless = true
    }

    let session = IOSPreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        deviceUDID: deviceUDID,
        compiler: iosCompiler,
        hostBuilder: hostBuilder,
        simulatorManager: simulatorManager,
        headless: headless
    )

    let pid = try await session.start()
    await iosState.addSession(session)

    // Set up file watching for hot-reload
    let sessionID = session.id
    let watcher = try? FileWatcher(path: fileURL.path) {
        Task {
            do {
                let wasLiteralOnly = try await session.handleSourceChange()
                if wasLiteralOnly {
                    fputs("MCP: iOS literal-only change applied (state preserved)\n", stderr)
                } else {
                    fputs("MCP: iOS structural change — recompiled\n", stderr)
                }
            } catch {
                fputs("MCP: iOS reload failed: \(error)\n", stderr)
            }
        }
    }
    if let watcher {
        await iosState.setFileWatcher(sessionID, watcher)
    }

    // Wait briefly for the app to launch and render
    try await Task.sleep(for: .seconds(2))

    return CallTool.Result(content: [.text("iOS simulator preview started on device \(deviceUDID). Session ID: \(sessionID). PID: \(pid). File is being watched for changes.")])
}

private func handlePreviewSnapshot(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    // Check if this is an iOS session
    if let iosSession = await iosState.getSession(sessionID) {
        let pngData = try await iosSession.screenshot()
        let base64 = pngData.base64EncodedString()
        return CallTool.Result(content: [
            .image(data: base64, mimeType: "image/png", metadata: nil)
        ])
    }

    // macOS path
    try await Task.sleep(for: .milliseconds(300))

    let pngData: Data = try await MainActor.run {
        guard let window = App.host.window(for: sessionID) else {
            throw SnapshotError.captureFailed
        }
        return try Snapshot.capture(window: window)
    }

    let base64 = pngData.base64EncodedString()

    return CallTool.Result(content: [
        .image(data: base64, mimeType: "image/png", metadata: nil)
    ])
}

private func handlePreviewStop(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    // Check if this is an iOS session
    if await iosState.getSession(sessionID) != nil {
        await iosState.removeSession(sessionID)
        return CallTool.Result(content: [.text("iOS preview session \(sessionID) closed.")])
    }

    // macOS path
    await MainActor.run {
        App.host.closePreview(sessionID: sessionID)
    }

    return CallTool.Result(content: [.text("Preview session \(sessionID) closed.")])
}

private func handlePreviewElements(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    guard let iosSession = await iosState.getSession(sessionID) else {
        return CallTool.Result(content: [.text("No iOS session found for \(sessionID). Elements are only available for iOS simulator previews.")], isError: true)
    }

    let elementsJSON = try await iosSession.fetchElements()
    return CallTool.Result(content: [.text(elementsJSON)])
}

private func handlePreviewTouch(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    guard let iosSession = await iosState.getSession(sessionID) else {
        return CallTool.Result(content: [.text("No iOS session found for \(sessionID). Touch is only supported for iOS simulator previews.")], isError: true)
    }

    let x: Double
    if case .double(let n) = params.arguments?["x"] {
        x = n
    } else if case .int(let n) = params.arguments?["x"] {
        x = Double(n)
    } else {
        return CallTool.Result(content: [.text("Missing x coordinate")], isError: true)
    }

    let y: Double
    if case .double(let n) = params.arguments?["y"] {
        y = n
    } else if case .int(let n) = params.arguments?["y"] {
        y = Double(n)
    } else {
        return CallTool.Result(content: [.text("Missing y coordinate")], isError: true)
    }

    let action: String
    if case .string(let a) = params.arguments?["action"] {
        action = a
    } else {
        action = "tap"
    }

    try await iosSession.sendTouch(x: x, y: y, action: action)

    // Wait briefly for the touch to register and UI to update
    try await Task.sleep(for: .milliseconds(200))

    return CallTool.Result(content: [.text("Touch \(action) sent at (\(Int(x)), \(Int(y)))")])
}

private func handleSimulatorList() async throws -> CallTool.Result {
    let manager = iosState.simulatorManager
    let devices = try await manager.listDevices()
    let available = devices.filter { $0.isAvailable }

    if available.isEmpty {
        return CallTool.Result(content: [.text("No available simulator devices found.")])
    }

    var lines: [String] = []
    for device in available {
        let state = device.state == .booted ? " [BOOTED]" : ""
        lines.append("\(device.name) — \(device.udid)\(state) (\(device.runtimeName ?? "unknown runtime"))")
    }

    return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
}
