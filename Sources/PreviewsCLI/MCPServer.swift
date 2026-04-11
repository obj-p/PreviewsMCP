import Foundation
import MCP
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS
import os

/// Tool names for MCP server. Used in both schema definitions and dispatch.
private enum ToolName: String {
    case previewList = "preview_list"
    case previewStart = "preview_start"
    case previewSnapshot = "preview_snapshot"
    case previewStop = "preview_stop"
    case previewConfigure = "preview_configure"
    case previewSwitch = "preview_switch"
    case previewElements = "preview_elements"
    case previewTouch = "preview_touch"
    case previewVariants = "preview_variants"
    case simulatorList = "simulator_list"
}

/// Tracks active iOS preview sessions and lazily creates shared iOS resources.
private actor IOSState {
    let simulatorManager = SimulatorManager()
    private var compiler: Compiler?
    private var hostBuilder: IOSHostBuilder?
    private var sessions: [String: IOSPreviewSession] = [:]
    private var fileWatchers: [String: FileWatcher] = [:]

    func getCompiler() async throws -> Compiler {
        if let c = compiler { return c }
        let c = try await Compiler(platform: .iOS)
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
private let configCache = ConfigCache()

private actor ConfigCache {
    private var cache: [String: ProjectConfig?] = [:]

    func config(for fileURL: URL) -> ProjectConfig? {
        let dir = fileURL.deletingLastPathComponent().standardizedFileURL.path
        if let cached = cache[dir] {
            return cached
        }
        let config = ProjectConfigLoader.find(from: fileURL.deletingLastPathComponent())
        cache[dir] = config
        return config
    }
}

/// MCP progress reporter that sends progress notifications and log messages to the client.
final class MCPProgressReporter: ProgressReporter, @unchecked Sendable {
    private let server: Server
    private let progressToken: ProgressToken?
    private let totalSteps: Int
    private let stepCounter: OSAllocatedUnfairLock<Int>

    init(server: Server, progressToken: ProgressToken?, totalSteps: Int) {
        self.server = server
        self.progressToken = progressToken
        self.totalSteps = totalSteps
        self.stepCounter = OSAllocatedUnfairLock(initialState: 0)
    }

    func report(_ phase: BuildPhase, message: String) async {
        let step = stepCounter.withLock { value -> Int in
            value += 1
            return value
        }
        try? await server.log(
            level: .info, logger: "preview",
            data: .string("[\(step)/\(totalSteps)] \(message)"))
        if let token = progressToken {
            try? await server.notify(
                ProgressNotification.message(
                    .init(
                        progressToken: token,
                        progress: Double(step),
                        total: Double(totalSteps),
                        message: message
                    )))
        }
    }
}

/// Create an MCP progress reporter for the given tool call parameters.
private func mcpReporter(
    server: Server, params: CallTool.Parameters, totalSteps: Int
) -> MCPProgressReporter {
    MCPProgressReporter(
        server: server,
        progressToken: params._meta?.progressToken,
        totalSteps: totalSteps
    )
}

/// Configures and returns an MCP server with preview tools.
func configureMCPServer() async throws -> (Server, Compiler) {
    // Clean up stale temp directories from previous sessions (older than 24 hours)
    cleanupStaleTempDirs()

    let compiler = try await Compiler()

    let server = Server(
        name: "previewsmcp",
        version: PreviewsMCPCommand.version,
        capabilities: .init(logging: .init(), tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [
            Tool(
                name: ToolName.previewList.rawValue,
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
                name: ToolName.previewStart.rawValue,
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
                            "description": .string("Target platform: 'macos' (default) or 'ios'"),
                        ]),
                        "deviceUDID": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Simulator device UDID (for ios; auto-selects if omitted)"),
                        ]),
                        "headless": .object([
                            "type": .string("boolean"),
                            "description": .string("If false, shows the preview window (default: true)"),
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
                                "Project root path (auto-detected if omitted). Enables importing project types from SPM packages, Bazel swift_library targets, or Xcode projects (.xcodeproj / .xcworkspace)."
                            ),
                        ]),
                        "scheme": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Xcode scheme name (only used for .xcodeproj / .xcworkspace projects). Required when the project contains more than one scheme and none of them match the source file's directory."
                            ),
                        ]),
                        "colorScheme": .object([
                            "type": .string("string"),
                            "enum": .array([.string("light"), .string("dark")]),
                            "description": .string("Color scheme override: 'light' or 'dark'"),
                        ]),
                        "dynamicTypeSize": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("xSmall"), .string("small"), .string("medium"),
                                .string("large"),
                                .string("xLarge"), .string("xxLarge"), .string("xxxLarge"),
                                .string("accessibility1"), .string("accessibility2"),
                                .string("accessibility3"),
                                .string("accessibility4"), .string("accessibility5"),
                            ]),
                            "description": .string(
                                "Dynamic Type size (e.g., 'large', 'accessibility3')"),
                        ]),
                        "locale": .object([
                            "type": .string("string"),
                            "description": .string(
                                "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP')"),
                        ]),
                        "layoutDirection": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("leftToRight"), .string("rightToLeft"),
                            ]),
                            "description": .string(
                                "Layout direction: 'leftToRight' or 'rightToLeft'"),
                        ]),
                        "legibilityWeight": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("regular"), .string("bold"),
                            ]),
                            "description": .string(
                                "Legibility weight: 'regular' or 'bold' (Bold Text accessibility)"
                            ),
                        ]),
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: ToolName.previewSnapshot.rawValue,
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
                name: ToolName.previewStop.rawValue,
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
                name: ToolName.previewConfigure.rawValue,
                description:
                    "Change rendering traits (color scheme, dynamic type, locale, layout direction, legibility weight) for a running preview. Triggers recompile; @State is reset. Pass empty string to clear a trait. Note: dynamicTypeSize only has a visible effect on iOS simulator — macOS does not scale fonts in response to this modifier.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                        "colorScheme": .object([
                            "type": .string("string"),
                            "enum": .array([.string("light"), .string("dark")]),
                            "description": .string("Color scheme override"),
                        ]),
                        "dynamicTypeSize": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("xSmall"), .string("small"), .string("medium"),
                                .string("large"),
                                .string("xLarge"), .string("xxLarge"), .string("xxxLarge"),
                                .string("accessibility1"), .string("accessibility2"),
                                .string("accessibility3"),
                                .string("accessibility4"), .string("accessibility5"),
                            ]),
                            "description": .string("Dynamic Type size override"),
                        ]),
                        "locale": .object([
                            "type": .string("string"),
                            "description": .string(
                                "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP'). Pass empty string to clear."
                            ),
                        ]),
                        "layoutDirection": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Layout direction: 'leftToRight' or 'rightToLeft'. Pass empty string to clear."
                            ),
                        ]),
                        "legibilityWeight": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Legibility weight: 'regular' or 'bold'. Pass empty string to clear."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: ToolName.previewSwitch.rawValue,
                description:
                    "Switch which #Preview block is rendered in a running session. Triggers recompile; @State is reset. Traits persist across switches.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                        "previewIndex": .object([
                            "type": .string("integer"),
                            "description": .string(
                                "0-based index of the #Preview block to switch to"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID"), .string("previewIndex")]),
                ])
            ),
            Tool(
                name: ToolName.previewElements.rawValue,
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
                name: ToolName.previewTouch.rawValue,
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
                name: ToolName.previewVariants.rawValue,
                description:
                    "Capture screenshots under multiple trait configurations in a single call. Renders each variant, snapshots it, then restores original traits. Accepts preset names or JSON trait objects.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                        "variants": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("string"),
                                "description": .string(
                                    "Preset name ('light', 'dark', 'xSmall'…'accessibility5', 'rtl', 'ltr', 'boldText') or a JSON object string with any combination of colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight, and an optional label."
                                ),
                            ]),
                            "description": .string(
                                "Array of trait variants to snapshot. Example: [\"light\", \"dark\", \"accessibility3\"]"
                            ),
                        ]),
                        "quality": .object([
                            "type": .string("number"),
                            "description": .string(
                                "JPEG quality 0.0-1.0 (default: 0.85). Values >= 1.0 produce PNG output."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("sessionID"), .string("variants")]),
                ])
            ),
            Tool(
                name: ToolName.simulatorList.rawValue,
                description: "List available iOS simulator devices with their UDIDs and states.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
        ])
    }

    await server.withMethodHandler(CallTool.self) { [server] params in
        guard let tool = ToolName(rawValue: params.name) else {
            return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
        switch tool {
        case .previewList:
            return try await handlePreviewList(params: params)
        case .previewStart:
            return try await handlePreviewStart(params: params, macCompiler: compiler, server: server)
        case .previewSnapshot:
            return try await handlePreviewSnapshot(params: params)
        case .previewConfigure:
            return try await handlePreviewConfigure(params: params, server: server)
        case .previewSwitch:
            return try await handlePreviewSwitch(params: params, server: server)
        case .previewStop:
            return try await handlePreviewStop(params: params)
        case .previewElements:
            return try await handlePreviewElements(params: params)
        case .previewTouch:
            return try await handlePreviewTouch(params: params)
        case .previewVariants:
            return try await handlePreviewVariants(params: params, server: server)
        case .simulatorList:
            return try await handleSimulatorList()
        }
    }

    return (server, compiler)
}

// MARK: - Tool Handlers

private func handlePreviewList(params: CallTool.Parameters) async throws -> CallTool.Result {
    let filePath: String
    do { filePath = try extractString("filePath", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
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
        lines.append("[\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)")
    }

    return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
}

private func handlePreviewStart(params: CallTool.Parameters, macCompiler: Compiler, server: Server) async throws
    -> CallTool.Result
{
    let filePath: String
    do { filePath = try extractString("filePath", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
    }

    let previewIndex = extractOptionalInt("previewIndex", from: params) ?? 0

    let config = await configCache.config(for: fileURL)
    let platformStr = extractOptionalString("platform", from: params) ?? config?.platform ?? "macos"

    let (explicitTraits, traitsError) = parseTraits(from: params)
    if let traitsError { return traitsError }
    let configTraits = config?.traits?.toPreviewTraits() ?? PreviewTraits()
    let resolvedTraits = configTraits.merged(with: explicitTraits)

    // iOS simulator path
    if platformStr == "ios" {
        return try await handleIOSPreviewStart(
            fileURL: fileURL,
            previewIndex: previewIndex,
            params: params,
            config: config,
            traits: resolvedTraits,
            server: server
        )
    }

    // macOS path (default)
    let width = extractOptionalInt("width", from: params) ?? 400
    let height = extractOptionalInt("height", from: params) ?? 600
    let headless = extractOptionalBool("headless", from: params) ?? true

    // Detect build system (auto-detect or explicit projectPath)
    let progress = mcpReporter(server: server, params: params, totalSteps: 3)
    let buildContext: BuildContext?
    do {
        buildContext = try await detectBuildContext(for: fileURL, params: params, platform: .macOS, progress: progress)
    } catch {
        return CallTool.Result(content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
    }

    // Build setup plugin if configured
    let configDir = fileURL.deletingLastPathComponent()
    let setupResult = try await buildSetupIfConfigured(config: config, configDirectory: configDir, platform: .macOS)
    let standaloneSetupWarning = (config?.setup != nil && buildContext == nil)
        ? " Warning: setup plugin requires a project build system and is ignored in standalone mode."
        : ""

    await progress.report(.compilingBridge, message: "Compiling \(fileURL.lastPathComponent)...")
    let sessionID = try await startMacOSPreview(
        fileURL: fileURL, previewIndex: previewIndex,
        title: "Preview: \(fileURL.lastPathComponent)",
        width: width, height: height,
        compiler: macCompiler, buildContext: buildContext,
        traits: resolvedTraits,
        setupResult: setupResult,
        headless: headless
    )

    let traitInfo = resolvedTraits.isEmpty ? "" : " Traits: \(traitsSummary(resolvedTraits))."
    let previews = try PreviewParser.parse(fileAt: fileURL)
    let previewList = formatPreviewList(previews: previews, activeIndex: previewIndex)
    let switchHint = previews.count > 1 ? "\nUse preview_switch to change the active preview." : ""
    return CallTool.Result(content: [
        .text(
            "macOS preview started. Session ID: \(sessionID).\(traitInfo)\(standaloneSetupWarning) File is being watched for changes.\n\(previewList)\(switchHint)"
        )
    ])
}

private func handleIOSPreviewStart(
    fileURL: URL,
    previewIndex: Int,
    params: CallTool.Parameters,
    config: ProjectConfig?,
    traits: PreviewTraits = PreviewTraits(),
    server: Server
) async throws -> CallTool.Result {
    // Resolve device UDID — use provided, config, or auto-select
    let deviceUDID: String
    let providedUDID = extractOptionalString("deviceUDID", from: params) ?? config?.device
    do {
        deviceUDID = try await resolveDeviceUDID(provided: providedUDID, using: iosState.simulatorManager)
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    let iosCompiler = try await iosState.getCompiler()
    let hostBuilder = try await iosState.getHostBuilder()
    let simulatorManager = iosState.simulatorManager

    let headless = extractOptionalBool("headless", from: params) ?? true

    // Detect build system
    let progress = mcpReporter(server: server, params: params, totalSteps: 8)
    let buildContext: BuildContext?
    do {
        buildContext = try await detectBuildContext(for: fileURL, params: params, platform: .iOS, progress: progress)
    } catch {
        return CallTool.Result(content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
    }

    let configDir = fileURL.deletingLastPathComponent()
    let setupResult = try await buildSetupIfConfigured(config: config, configDirectory: configDir, platform: .iOS)

    let session = IOSPreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        deviceUDID: deviceUDID,
        compiler: iosCompiler,
        hostBuilder: hostBuilder,
        simulatorManager: simulatorManager,
        headless: headless,
        buildContext: buildContext,
        traits: traits,
        setupModule: setupResult?.moduleName,
        setupType: setupResult?.typeName,
        setupCompilerFlags: setupResult?.compilerFlags ?? [],
        progress: progress
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

    let traitInfo = traits.isEmpty ? "" : " Traits: \(traitsSummary(traits))."
    let previews = try PreviewParser.parse(fileAt: fileURL)
    let previewList = formatPreviewList(previews: previews, activeIndex: previewIndex)
    let switchHint = previews.count > 1 ? "\nUse preview_switch to change the active preview." : ""
    return CallTool.Result(content: [
        .text(
            "iOS simulator preview started on device \(deviceUDID). Session ID: \(sessionID). PID: \(pid).\(traitInfo) File is being watched for changes.\n\(previewList)\(switchHint)"
        )
    ])
}

/// Build the setup package if configured. Returns nil if no setup or standalone mode.
private func buildSetupIfConfigured(
    config: ProjectConfig?,
    configDirectory: URL,
    platform: PreviewPlatform
) async throws -> SetupBuilder.Result? {
    guard let setupConfig = config?.setup else { return nil }
    let configDir = ProjectConfigLoader.findConfigDirectory(from: configDirectory) ?? configDirectory
    return try await SetupBuilder.build(
        config: setupConfig, configDirectory: configDir, platform: platform
    )
}

private func startMacOSPreview(
    fileURL: URL, previewIndex: Int, title: String,
    width: Int, height: Int,
    compiler: Compiler, buildContext: BuildContext?,
    traits: PreviewTraits = PreviewTraits(),
    setupResult: SetupBuilder.Result? = nil,
    headless: Bool = true
) async throws -> String {
    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: compiler,
        buildContext: buildContext,
        traits: traits,
        setupModule: setupResult?.moduleName,
        setupType: setupResult?.typeName,
        setupCompilerFlags: setupResult?.compilerFlags ?? []
    )

    let compileResult = try await session.compile()
    let sessionID = session.id

    await MainActor.run {
        do {
            try App.host.loadPreview(
                sessionID: sessionID,
                dylibPath: compileResult.dylibPath,
                title: title,
                size: NSSize(width: width, height: height),
                headless: headless
            )
            App.host.watchFile(
                sessionID: sessionID,
                session: session,
                filePath: fileURL.path,
                compiler: compiler,
                additionalPaths: buildContext?.sourceFiles?.map(\.path) ?? [],
                buildContext: buildContext
            )
        } catch {
            fputs("MCP: Failed to load preview: \(error)\n", stderr)
        }
    }

    return sessionID
}

private func handlePreviewSnapshot(params: CallTool.Parameters) async throws -> CallTool.Result {
    let sessionID: String
    do { sessionID = try extractString("sessionID", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    let configQuality: Double? = if let iosSession = await iosState.getSession(sessionID) {
        await configCache.config(for: iosSession.sourceFile)?.quality
    } else {
        nil
    }
    let quality = max(0.0, min(1.0, extractOptionalDouble("quality", from: params) ?? configQuality ?? 0.85))
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
    let sessionID: String
    do { sessionID = try extractString("sessionID", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    // Check if this is an iOS session
    if let iosSession = await iosState.getSession(sessionID) {
        await iosSession.stop()
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
    let sessionID: String
    do { sessionID = try extractString("sessionID", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    guard let iosSession = await iosState.getSession(sessionID) else {
        return CallTool.Result(
            content: [
                .text("No iOS session found for \(sessionID). Elements are only available for iOS simulator previews.")
            ], isError: true)
    }

    let validFilters: Set<String> = ["all", "interactable", "labeled"]
    let filter = extractOptionalString("filter", from: params) ?? "all"
    guard validFilters.contains(filter) else {
        return CallTool.Result(
            content: [.text("Invalid filter '\(filter)'. Must be one of: all, interactable, labeled")], isError: true)
    }

    let elementsJSON = try await iosSession.fetchElements(filter: filter)
    return CallTool.Result(content: [.text(elementsJSON)])
}

private func handlePreviewTouch(params: CallTool.Parameters) async throws -> CallTool.Result {
    let sessionID: String
    let x: Double
    let y: Double
    do {
        sessionID = try extractString("sessionID", from: params)
        x = try extractDouble("x", from: params)
        y = try extractDouble("y", from: params)
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    guard let iosSession = await iosState.getSession(sessionID) else {
        return CallTool.Result(
            content: [
                .text("No iOS session found for \(sessionID). Touch is only supported for iOS simulator previews.")
            ], isError: true)
    }

    let action = extractOptionalString("action", from: params) ?? "tap"

    if action == "swipe" {
        let toX: Double
        let toY: Double
        do {
            toX = try extractDouble("toX", from: params)
            toY = try extractDouble("toY", from: params)
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        let duration = extractOptionalDouble("duration", from: params) ?? 0.3

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
    platform: PreviewPlatform,
    progress: (any ProgressReporter)? = nil
) async throws -> BuildContext? {
    let projectRootURL = extractOptionalString("projectPath", from: params).map { URL(fileURLWithPath: $0) }
    let scheme = extractOptionalString("scheme", from: params)
    return try await detectAndBuild(
        for: fileURL,
        projectRoot: projectRootURL,
        platform: platform,
        scheme: scheme,
        progress: progress
    )
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

// MARK: - Trait Helpers

/// Parse and validate trait parameters. Returns (traits, nil) on success or (default traits, error result) on failure.
/// Callers should check the second element first; the traits value is meaningless when an error is returned.
private func parseTraits(from params: CallTool.Parameters) -> (PreviewTraits, CallTool.Result?) {
    do {
        let traits = try PreviewTraits.validated(
            colorScheme: extractOptionalString("colorScheme", from: params),
            dynamicTypeSize: extractOptionalString("dynamicTypeSize", from: params),
            locale: extractOptionalString("locale", from: params),
            layoutDirection: extractOptionalString("layoutDirection", from: params),
            legibilityWeight: extractOptionalString("legibilityWeight", from: params)
        )
        return (traits, nil)
    } catch {
        return (PreviewTraits(), CallTool.Result(content: [.text(error.localizedDescription)], isError: true))
    }
}

private func traitsSummary(_ traits: PreviewTraits) -> String {
    var parts: [String] = []
    if let cs = traits.colorScheme { parts.append("colorScheme=\(cs)") }
    if let dts = traits.dynamicTypeSize { parts.append("dynamicTypeSize=\(dts)") }
    if let loc = traits.locale { parts.append("locale=\(loc)") }
    if let ld = traits.layoutDirection { parts.append("layoutDirection=\(ld)") }
    if let lw = traits.legibilityWeight { parts.append("legibilityWeight=\(lw)") }
    return parts.joined(separator: ", ")
}

private func handlePreviewConfigure(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
    let sessionID: String
    do { sessionID = try extractString("sessionID", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    // Parse and validate traits
    let (traits, validationError) = parseTraits(from: params)
    if let validationError { return validationError }

    if traits.isEmpty {
        return CallTool.Result(content: [.text("No configuration changes specified.")])
    }

    let progress = mcpReporter(server: server, params: params, totalSteps: 1)

    // iOS path
    if let iosSession = await iosState.getSession(sessionID) {
        await progress.report(.compilingBridge, message: "Recompiling with new traits...")
        try await iosSession.reconfigure(traits: traits)
        let activeTraits = await iosSession.currentTraits
        return CallTool.Result(content: [
            .text(
                "Configured session \(sessionID): \(traitsSummary(activeTraits)). View recompiled (@State was reset)."
            )
        ])
    }

    // macOS path
    let session: PreviewSession? = await MainActor.run { App.host.session(for: sessionID) }
    guard let session else {
        return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
    }

    await progress.report(.compilingBridge, message: "Recompiling with new traits...")
    let compileResult = try await session.reconfigure(traits: traits)
    try await MainActor.run {
        try App.host.loadPreview(sessionID: sessionID, dylibPath: compileResult.dylibPath)
    }

    let activeTraits = await session.currentTraits
    return CallTool.Result(content: [
        .text(
            "Configured session \(sessionID): \(traitsSummary(activeTraits)). View recompiled (@State was reset)."
        )
    ])
}

// MARK: - preview_variants

private enum VariantError: Error, LocalizedError {
    case invalidVariantType
    case emptyVariantsArray

    var errorDescription: String? {
        switch self {
        case .invalidVariantType:
            return
                "Each variant must be a preset name string or a JSON object string with trait fields (colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight)"
        case .emptyVariantsArray:
            return "variants array must not be empty"
        }
    }
}

/// Unwrap an MCP Value to a String, then resolve via PreviewTraits.parseVariantString.
private func resolveVariant(_ value: Value) throws -> PreviewTraits.Variant {
    guard case .string(let str) = value else {
        throw VariantError.invalidVariantType
    }
    return try PreviewTraits.parseVariantString(str)
}

private func handlePreviewVariants(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
    let sessionID: String
    let variantValues: [Value]
    do {
        sessionID = try extractString("sessionID", from: params)
        variantValues = try extractArray("variants", from: params)
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    guard !variantValues.isEmpty else {
        return CallTool.Result(
            content: [.text(VariantError.emptyVariantsArray.localizedDescription)], isError: true)
    }

    // Resolve all variants upfront — fail fast on validation errors before any recompilation
    let resolved: [PreviewTraits.Variant]
    do {
        resolved = try variantValues.map { try resolveVariant($0) }
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    let variantConfigQuality: Double? = if let iosSession = await iosState.getSession(sessionID) {
        await configCache.config(for: iosSession.sourceFile)?.quality
    } else {
        nil
    }
    let quality = max(0.0, min(1.0, extractOptionalDouble("quality", from: params) ?? variantConfigQuality ?? 0.85))
    let usePNG = quality >= 1.0
    let mimeType = usePNG ? "image/png" : "image/jpeg"
    let progress = mcpReporter(server: server, params: params, totalSteps: 2 * resolved.count)

    // iOS path
    if let iosSession = await iosState.getSession(sessionID) {
        let savedTraits = await iosSession.currentTraits
        var contentBlocks: [Tool.Content] = []
        var failCount = 0

        for (index, variant) in resolved.enumerated() {
            do {
                await progress.report(
                    .compilingBridge, message: "Recompiling for variant \"\(variant.label)\"...")
                try await iosSession.setTraits(variant.traits)
                await progress.report(
                    .capturingSnapshot,
                    message: "Capturing variant \(index + 1)/\(resolved.count) \"\(variant.label)\"...")
                let imageData = try await iosSession.screenshot(jpegQuality: quality)
                let base64 = imageData.base64EncodedString()
                contentBlocks.append(.text("[\(index)] \(variant.label):"))
                contentBlocks.append(.image(data: base64, mimeType: mimeType, metadata: nil))
            } catch {
                failCount += 1
                contentBlocks.append(
                    .text("[\(index)] \(variant.label): ERROR — \(error.localizedDescription)"))
            }
        }

        // Restore original traits if they changed
        let currentTraits = await iosSession.currentTraits
        if savedTraits != currentTraits {
            do {
                try await iosSession.setTraits(savedTraits)
            } catch {
                contentBlocks.append(
                    .text("Warning: failed to restore original traits: \(error.localizedDescription)")
                )
            }
        }

        return CallTool.Result(content: contentBlocks, isError: failCount == resolved.count)
    }

    // macOS path
    let session: PreviewSession? = await MainActor.run { App.host.session(for: sessionID) }
    guard let session else {
        return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
    }

    let savedTraits = await session.currentTraits
    var contentBlocks: [Tool.Content] = []
    var failCount = 0
    let format: Snapshot.ImageFormat = usePNG ? .png : .jpeg(quality: quality)

    for (index, variant) in resolved.enumerated() {
        do {
            await progress.report(
                .compilingBridge, message: "Recompiling for variant \"\(variant.label)\"...")
            let compileResult = try await session.setTraits(variant.traits)
            try await MainActor.run {
                try App.host.loadPreview(sessionID: sessionID, dylibPath: compileResult.dylibPath)
            }
            try await Task.sleep(for: .milliseconds(300))
            await progress.report(
                .capturingSnapshot,
                message: "Capturing variant \(index + 1)/\(resolved.count) \"\(variant.label)\"...")
            let imageData: Data = try await MainActor.run {
                guard let window = App.host.window(for: sessionID) else {
                    throw SnapshotError.captureFailed
                }
                return try Snapshot.capture(window: window, format: format)
            }
            let base64 = imageData.base64EncodedString()
            contentBlocks.append(.text("[\(index)] \(variant.label):"))
            contentBlocks.append(.image(data: base64, mimeType: mimeType, metadata: nil))
        } catch {
            failCount += 1
            contentBlocks.append(
                .text("[\(index)] \(variant.label): ERROR — \(error.localizedDescription)"))
        }
    }

    // Restore original traits if they changed
    let currentTraits = await session.currentTraits
    if savedTraits != currentTraits {
        do {
            let restoreResult = try await session.setTraits(savedTraits)
            try await MainActor.run {
                try App.host.loadPreview(sessionID: sessionID, dylibPath: restoreResult.dylibPath)
            }
        } catch {
            contentBlocks.append(
                .text("Warning: failed to restore original traits: \(error.localizedDescription)"))
        }
    }

    return CallTool.Result(content: contentBlocks, isError: failCount == resolved.count)
}

private func handlePreviewSwitch(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
    let sessionID: String
    let newIndex: Int
    do {
        sessionID = try extractString("sessionID", from: params)
        newIndex = try extractInt("previewIndex", from: params)
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    let progress = mcpReporter(server: server, params: params, totalSteps: 1)

    // iOS path
    if let iosSession = await iosState.getSession(sessionID) {
        await progress.report(.compilingBridge, message: "Switching to preview \(newIndex)...")
        try await iosSession.switchPreview(to: newIndex)
        let activeTraits = await iosSession.currentTraits
        let traitInfo = activeTraits.isEmpty ? "" : " Traits: \(traitsSummary(activeTraits))."

        let previews = try PreviewParser.parse(fileAt: iosSession.sourceFile)
        let previewList = formatPreviewList(previews: previews, activeIndex: newIndex)
        return CallTool.Result(content: [
            .text(
                "Switched to preview \(newIndex) in session \(sessionID).\(traitInfo) View recompiled (@State was reset).\n\(previewList)"
            )
        ])
    }

    // macOS path
    let session: PreviewSession? = await MainActor.run { App.host.session(for: sessionID) }
    guard let session else {
        return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
    }

    await progress.report(.compilingBridge, message: "Switching to preview \(newIndex)...")
    let compileResult = try await session.switchPreview(to: newIndex)
    try await MainActor.run {
        try App.host.loadPreview(sessionID: sessionID, dylibPath: compileResult.dylibPath)
    }

    let activeTraits = await session.currentTraits
    let traitInfo = activeTraits.isEmpty ? "" : " Traits: \(traitsSummary(activeTraits))."

    let previews = try PreviewParser.parse(fileAt: session.sourceFile)
    let previewList = formatPreviewList(previews: previews, activeIndex: newIndex)
    return CallTool.Result(content: [
        .text(
            "Switched to preview \(newIndex) in session \(sessionID).\(traitInfo) View recompiled (@State was reset).\n\(previewList)"
        )
    ])
}

private func formatPreviewList(previews: [PreviewInfo], activeIndex: Int) -> String {
    var lines: [String] = ["Available previews:"]
    for preview in previews {
        let name = preview.name ?? "Preview"
        let marker = preview.index == activeIndex ? " <- active" : ""
        lines.append("  [\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)\(marker)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Parameter Extraction Helpers

private enum ParamError: Error, LocalizedError {
    case missing(String)
    case wrongType(key: String, expected: String)

    var errorDescription: String? {
        switch self {
        case .missing(let key): return "Missing \(key) parameter"
        case .wrongType(let key, let expected): return "Parameter \(key) must be \(expected)"
        }
    }
}

private func extractString(_ key: String, from params: CallTool.Parameters) throws -> String {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    guard case .string(let str) = value else { throw ParamError.wrongType(key: key, expected: "a string") }
    return str
}

private func extractOptionalString(_ key: String, from params: CallTool.Parameters) -> String? {
    if case .string(let value) = params.arguments?[key] { return value }
    return nil
}

private func extractInt(_ key: String, from params: CallTool.Parameters) throws -> Int {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    if case .int(let n) = value { return n }
    if case .double(let n) = value, let int = Int(exactly: n) { return int }
    throw ParamError.wrongType(key: key, expected: "an integer")
}

private func extractOptionalInt(_ key: String, from params: CallTool.Parameters) -> Int? {
    if case .int(let value) = params.arguments?[key] { return value }
    if case .double(let value) = params.arguments?[key], let int = Int(exactly: value) { return int }
    return nil
}

private func extractDouble(_ key: String, from params: CallTool.Parameters) throws -> Double {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    if case .double(let n) = value { return n }
    if case .int(let n) = value { return Double(n) }
    throw ParamError.wrongType(key: key, expected: "a number")
}

private func extractOptionalDouble(_ key: String, from params: CallTool.Parameters) -> Double? {
    if case .double(let value) = params.arguments?[key] { return value }
    if case .int(let value) = params.arguments?[key] { return Double(value) }
    return nil
}

private func extractOptionalBool(_ key: String, from params: CallTool.Parameters) -> Bool? {
    if case .bool(let value) = params.arguments?[key] { return value }
    return nil
}

private func extractArray(_ key: String, from params: CallTool.Parameters) throws -> [Value] {
    guard let value = params.arguments?[key] else { throw ParamError.missing(key) }
    guard case .array(let arr) = value else { throw ParamError.wrongType(key: key, expected: "an array") }
    return arr
}

/// Remove stale previewsmcp temp directories older than 24 hours.
private func cleanupStaleTempDirs() {
    let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent("previewsmcp")
    guard
        let contents = try? FileManager.default.contentsOfDirectory(
            at: tempBase, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }

    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for dir in contents {
        guard let attrs = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
            let modDate = attrs.contentModificationDate,
            modDate < cutoff
        else { continue }
        try? FileManager.default.removeItem(at: dir)
        fputs("MCP: Cleaned up stale temp dir: \(dir.lastPathComponent)\n", stderr)
    }
}
