import Foundation
import MCP
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

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
        name: "previewsmcp",
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
                        ])
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: "preview_start",
                description:
                    "Compile and launch a live SwiftUI preview. Returns a session ID. Supports macOS (default) and iOS simulator.",
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
                            "description": .string(
                                "Simulator device UDID (for ios-simulator; auto-selects if omitted)"),
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
                        "projectPath": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Project root path (auto-detected if omitted). Enables importing project types from SPM packages or Bazel swift_library targets."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: "preview_snapshot",
                description: "Capture a screenshot of a running preview. Returns the image as JPEG (default) or PNG.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                        "quality": .object([
                            "type": .string("number"),
                            "description": .string(
                                "JPEG quality 0.0–1.0 (default: 0.85). Values >= 1.0 produce PNG output."),
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
                        ])
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: "preview_elements",
                description:
                    "Get the accessibility tree of an iOS simulator preview. Returns elements with labels, frames, and traits for targeted interaction.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start (iOS simulator only)"),
                        ]),
                        "filter": .object([
                            "type": .string("string"),
                            "enum": .array([.string("all"), .string("interactable"), .string("labeled")]),
                            "description": .string(
                                "Filter mode: 'all' (default) returns the full tree, 'interactable' returns only buttons/links/toggles, 'labeled' returns only elements with label/value/identifier"
                            ),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: "preview_touch",
                description:
                    "Send a touch event to an iOS simulator preview. Coordinates are in device points. For swipe, x/y is the start point.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start (iOS simulator only)"),
                        ]),
                        "x": .object([
                            "type": .string("number"),
                            "description": .string("X coordinate in points (start point for swipe)"),
                        ]),
                        "y": .object([
                            "type": .string("number"),
                            "description": .string("Y coordinate in points (start point for swipe)"),
                        ]),
                        "action": .object([
                            "type": .string("string"),
                            "description": .string("'tap' (default) or 'swipe'"),
                        ]),
                        "toX": .object([
                            "type": .string("number"),
                            "description": .string("End X for swipe"),
                        ]),
                        "toY": .object([
                            "type": .string("number"),
                            "description": .string("End Y for swipe"),
                        ]),
                        "duration": .object([
                            "type": .string("number"),
                            "description": .string("Swipe duration in seconds (default: 0.3)"),
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

    // Detect build system (auto-detect or explicit projectPath)
    let buildContext: BuildContext?
    do {
        buildContext = try await detectBuildContext(for: fileURL, params: params, platform: .macOS)
    } catch {
        return CallTool.Result(content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
    }

    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: macCompiler,
        buildContext: buildContext
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
                previewIndex: previewIndex,
                additionalPaths: buildContext?.sourceFiles?.map(\.path) ?? [],
                buildContext: buildContext
            )
        } catch {
            fputs("MCP: Failed to load preview: \(error)\n", stderr)
        }
    }

    return CallTool.Result(content: [
        .text("macOS preview started. Session ID: \(sessionID). File is being watched for changes.")
    ])
}

private func handleIOSPreviewStart(
    fileURL: URL,
    previewIndex: Int,
    params: CallTool.Parameters
) async throws -> CallTool.Result {
    // Resolve device UDID — use provided or auto-select
    let deviceUDID: String
    let providedUDID: String? = if case .string(let udid) = params.arguments?["deviceUDID"] { udid } else { nil }
    do {
        deviceUDID = try await resolveDeviceUDID(provided: providedUDID, using: iosState.simulatorManager)
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
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

    // Detect build system
    let buildContext: BuildContext?
    do {
        buildContext = try await detectBuildContext(for: fileURL, params: params, platform: .iOSSimulator)
    } catch {
        return CallTool.Result(content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
    }

    let session = IOSPreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        deviceUDID: deviceUDID,
        compiler: iosCompiler,
        hostBuilder: hostBuilder,
        simulatorManager: simulatorManager,
        headless: headless,
        buildContext: buildContext
    )

    let pid = try await session.start()
    await iosState.addSession(session)

    // Set up file watching for hot-reload
    let sessionID = session.id
    let allPaths = [fileURL.path] + (buildContext?.sourceFiles?.map(\.path) ?? [])
    let watcher = try? FileWatcher(paths: allPaths) {
        Task {
            fputs("MCP: iOS file change detected, reloading session \(sessionID)...\n", stderr)
            do {
                let wasLiteralOnly = try await session.handleSourceChange()
                if wasLiteralOnly {
                    fputs("MCP: iOS literal-only change applied (state preserved)\n", stderr)
                } else {
                    fputs("MCP: iOS structural change — recompiled and signalled reload\n", stderr)
                }
            } catch {
                fputs("MCP: iOS reload failed for session \(sessionID): \(error)\n", stderr)
            }
        }
    }
    if let watcher {
        await iosState.setFileWatcher(sessionID, watcher)
    }

    // Wait briefly for the app to launch and render
    try await Task.sleep(for: .seconds(2))

    return CallTool.Result(content: [
        .text(
            "iOS simulator preview started on device \(deviceUDID). Session ID: \(sessionID). PID: \(pid). File is being watched for changes."
        )
    ])
}

private func handlePreviewSnapshot(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    // Parse quality parameter (default 0.85 = JPEG)
    let quality: Double
    if case .double(let q) = params.arguments?["quality"] {
        quality = max(0.0, min(1.5, q))
    } else if case .int(let n) = params.arguments?["quality"] {
        quality = max(0.0, min(1.5, Double(n)))
    } else {
        quality = 0.85
    }
    let usePNG = quality >= 1.0
    let mimeType = usePNG ? "image/png" : "image/jpeg"

    // Check if this is an iOS session
    if let iosSession = await iosState.getSession(sessionID) {
        let imageData = try await iosSession.screenshot(jpegQuality: quality)
        let base64 = imageData.base64EncodedString()
        return CallTool.Result(content: [
            .image(data: base64, mimeType: mimeType, metadata: nil)
        ])
    }

    // macOS path
    try await Task.sleep(for: .milliseconds(300))

    let format: Snapshot.ImageFormat = usePNG ? .png : .jpeg(quality: quality)
    let imageData: Data = try await MainActor.run {
        guard let window = App.host.window(for: sessionID) else {
            throw SnapshotError.captureFailed
        }
        return try Snapshot.capture(window: window, format: format)
    }

    let base64 = imageData.base64EncodedString()

    return CallTool.Result(content: [
        .image(data: base64, mimeType: mimeType, metadata: nil)
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
        return CallTool.Result(
            content: [
                .text("No iOS session found for \(sessionID). Elements are only available for iOS simulator previews.")
            ], isError: true)
    }

    let validFilters: Set<String> = ["all", "interactable", "labeled"]
    let filter: String
    if case .string(let f) = params.arguments?["filter"] {
        guard validFilters.contains(f) else {
            return CallTool.Result(
                content: [.text("Invalid filter '\(f)'. Must be one of: all, interactable, labeled")], isError: true)
        }
        filter = f
    } else {
        filter = "all"
    }

    let elementsJSON = try await iosSession.fetchElements(filter: filter)
    return CallTool.Result(content: [.text(elementsJSON)])
}

private func handlePreviewTouch(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    guard let iosSession = await iosState.getSession(sessionID) else {
        return CallTool.Result(
            content: [
                .text("No iOS session found for \(sessionID). Touch is only supported for iOS simulator previews.")
            ], isError: true)
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

    if action == "swipe" {
        // Swipe requires fromX/fromY (use x/y) and toX/toY
        let toX: Double
        if case .double(let n) = params.arguments?["toX"] {
            toX = n
        } else if case .int(let n) = params.arguments?["toX"] {
            toX = Double(n)
        } else {
            return CallTool.Result(content: [.text("Missing toX for swipe")], isError: true)
        }

        let toY: Double
        if case .double(let n) = params.arguments?["toY"] {
            toY = n
        } else if case .int(let n) = params.arguments?["toY"] {
            toY = Double(n)
        } else {
            return CallTool.Result(content: [.text("Missing toY for swipe")], isError: true)
        }

        let duration: Double = {
            if case .double(let n) = params.arguments?["duration"] { return n }
            return 0.3
        }()

        try await iosSession.sendSwipe(fromX: x, fromY: y, toX: toX, toY: toY, duration: duration)
        return CallTool.Result(content: [.text("Swipe from (\(Int(x)),\(Int(y))) to (\(Int(toX)),\(Int(toY)))")])
    }

    try await iosSession.sendTap(x: x, y: y)

    // Wait briefly for the touch to register and UI to update
    try await Task.sleep(for: .milliseconds(300))

    return CallTool.Result(content: [.text("Tap sent at (\(Int(x)), \(Int(y)))")])
}

private func detectBuildContext(
    for fileURL: URL,
    params: CallTool.Parameters,
    platform: PreviewPlatform
) async throws -> BuildContext? {
    let projectRootURL: URL?
    if case .string(let path) = params.arguments?["projectPath"] {
        projectRootURL = URL(fileURLWithPath: path)
    } else {
        projectRootURL = nil
    }
    return try await detectAndBuild(for: fileURL, projectRoot: projectRootURL, platform: platform, logPrefix: "MCP:")
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
