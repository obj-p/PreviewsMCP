import Foundation
import MCP
import PreviewsCore
import PreviewsEngine
import PreviewsIOS
import PreviewsMacOS
import os

/// File-private references to the shared engine-layer instances.
/// Set once per daemon lifetime by `configureMCPServer(host:iosManager:configCache:)`.
/// All handler functions reference these instead of globals.
@MainActor private var host: PreviewHost!
@MainActor private var iosState: IOSSessionManager!
@MainActor private var configCache: ConfigCache!

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
///
/// - Parameter sharedCompiler: Pass a pre-built `Compiler` to reuse across
///   multiple server instances (e.g., daemon mode, where each accepted client
///   connection gets its own `Server` but they all share one compiler). When
///   nil, a fresh compiler is built — appropriate for single-connection modes
///   like stdio.
func configureMCPServer(
    host previewHost: PreviewHost,
    iosManager: IOSSessionManager,
    configCache cache: ConfigCache,
    sharedCompiler: Compiler? = nil
) async throws -> (Server, Compiler) {
    await MainActor.run {
        if host == nil { host = previewHost }
        if iosState == nil { iosState = iosManager }
        if configCache == nil { configCache = cache }
    }

    cleanupStaleTempDirs()

    let compiler: Compiler
    if let sharedCompiler {
        compiler = sharedCompiler
    } else {
        compiler = try await Compiler()
    }

    let server = Server(
        name: "previewsmcp",
        version: PreviewsMCPCommand.version,
        capabilities: .init(logging: .init(), tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: mcpToolSchemas())
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
        case .sessionList:
            return await handleSessionList()
        }
    }

    return (server, compiler)
}

/// Run the MCP server's event loop on `transport`, emitting a periodic
/// heartbeat log notification that clients can use as a liveness signal.
/// Returns when the transport closes (client disconnected or server
/// shutdown). The heartbeat Task is cancelled on return.
///
/// Why the heartbeat: daemon handlers can be legitimately silent for
/// long stretches (swiftc recompiles, simulator boot), and stall-
/// detection layers downstream have no way to distinguish that from a
/// genuinely wedged daemon. A 2s unconditional ping fires regardless of
/// whether any tool call is in flight, covering both the
/// request-scoped silence and the between-request silence (e.g., the
/// FileWatcher reload path — see issue #135).
///
/// Why `LogMessageNotification` with `logger: "heartbeat"` rather than
/// `ProgressNotification`: per the MCP spec, progress notifications
/// require a `progressToken` from an in-flight request. An unsolicited
/// heartbeat has no such token. `LogMessageNotification`'s optional
/// `logger` discriminator lets clients filter these out of human-visible
/// log surfaces (see `DaemonClient.registerStderrLogForwarder`) while
/// still receiving them as liveness-timer bumps.
///
/// Timing contract for downstream consumers (Phase 2 stall detector): the
/// first ping fires at T+2s relative to `server.start`, not T+0. A
/// client-side liveness timer should grant at least one full heartbeat
/// interval of grace on connect before declaring the daemon wedged.
func runMCPServer(_ server: Server, transport: any Transport) async throws {
    let heartbeat = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            try? await server.log(
                level: .debug, logger: "heartbeat", data: .string("alive"))
        }
    }
    defer { heartbeat.cancel() }
    try await server.start(transport: transport)
    // `server.start` returns once its internal receive Task is spawned,
    // NOT when the transport closes. Wait explicitly so the heartbeat's
    // defer-cancel fires only after the server is actually done serving.
    await server.waitUntilCompleted()
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

    // Structured payload — always safe to emit, even for empty lists.
    // No session is active here so `activeIndex: -1` sentinel means
    // no `.active == true` entries.
    let structured = DaemonProtocol.PreviewListResult(
        file: fileURL.path,
        previews: previews.map {
            DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: -1)
        }
    )

    if previews.isEmpty {
        return try CallTool.Result(
            content: [.text("No #Preview blocks found in \(fileURL.lastPathComponent)")],
            structuredContent: structured
        )
    }

    var lines: [String] = []
    for preview in previews {
        let name = preview.name ?? "Preview"
        lines.append("[\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)")
    }

    return try CallTool.Result(
        content: [.text(lines.joined(separator: "\n"))],
        structuredContent: structured
    )
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

    let configResult = await configCache.load(for: fileURL)
    let config = configResult?.config
    let platformStr: String
    if let explicit = extractOptionalString("platform", from: params) {
        platformStr = explicit
    } else if let configPlatform = config?.platform {
        platformStr = configPlatform
    } else if await SPMBuildSystem.inferredPlatformAsync(for: fileURL) == .iOS {
        platformStr = "ios"
    } else {
        platformStr = "macos"
    }

    // preview_start ignores clearedFields — traits start from empty so there's
    // nothing to clear. Only preview_configure treats clearing meaningfully.
    let (explicitTraits, _, traitsError) = parseTraits(from: params)
    if let traitsError { return traitsError }
    let configTraits = config?.traits?.toPreviewTraits() ?? PreviewTraits()
    let resolvedTraits = configTraits.merged(with: explicitTraits)

    // iOS simulator path
    if platformStr == "ios" {
        return try await handleIOSPreviewStart(
            fileURL: fileURL,
            previewIndex: previewIndex,
            params: params,
            configResult: configResult,
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
    let setupResult = try await buildSetupIfConfigured(
        config: config, configDirectory: configResult?.directory, platform: .macOS
    )
    let standaloneSetupWarning =
        (config?.setup != nil && buildContext == nil)
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
    let structured = DaemonProtocol.PreviewStartResult(
        sessionID: sessionID,
        platform: "macos",
        sourceFilePath: fileURL.path,
        deviceUDID: nil,
        pid: nil,
        traits: DaemonProtocol.TraitsDTO.orNil(resolvedTraits),
        previews: previews.map {
            DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: previewIndex)
        },
        activeIndex: previewIndex,
        setupWarning: standaloneSetupWarning.isEmpty ? nil : standaloneSetupWarning
    )
    return try CallTool.Result(
        content: [
            .text(
                "macOS preview started. Session ID: \(sessionID).\(traitInfo)\(standaloneSetupWarning) File is being watched for changes.\n\(previewList)\(switchHint)"
            )
        ],
        structuredContent: structured
    )
}

private func handleIOSPreviewStart(
    fileURL: URL,
    previewIndex: Int,
    params: CallTool.Parameters,
    configResult: ProjectConfigLoader.Result?,
    traits: PreviewTraits = PreviewTraits(),
    server: Server
) async throws -> CallTool.Result {
    let config = configResult?.config
    // Resolve device UDID — use provided, config, or auto-select
    let deviceUDID: String
    let providedUDID = extractOptionalString("deviceUDID", from: params) ?? config?.device
    do {
        deviceUDID = try await resolveDeviceUDID(provided: providedUDID, using: await iosState.simulatorManager)
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    let iosCompiler = try await iosState.getCompiler()
    let hostBuilder = try await iosState.getHostBuilder()
    let simulatorManager = await iosState.simulatorManager

    let headless = extractOptionalBool("headless", from: params) ?? true

    // Detect build system
    let progress = mcpReporter(server: server, params: params, totalSteps: 8)
    let buildContext: BuildContext?
    do {
        buildContext = try await detectBuildContext(for: fileURL, params: params, platform: .iOS, progress: progress)
    } catch {
        return CallTool.Result(content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
    }

    let setupResult = try await buildSetupIfConfigured(
        config: config, configDirectory: configResult?.directory, platform: .iOS)

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
        setupDylibPath: setupResult?.dylibPath,
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
    let structured = DaemonProtocol.PreviewStartResult(
        sessionID: sessionID,
        platform: "ios",
        sourceFilePath: fileURL.path,
        deviceUDID: deviceUDID,
        pid: Int(pid),
        traits: DaemonProtocol.TraitsDTO.orNil(traits),
        previews: previews.map {
            DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: previewIndex)
        },
        activeIndex: previewIndex,
        setupWarning: nil
    )
    return try CallTool.Result(
        content: [
            .text(
                "iOS simulator preview started on device \(deviceUDID). Session ID: \(sessionID). PID: \(pid).\(traitInfo) File is being watched for changes.\n\(previewList)\(switchHint)"
            )
        ],
        structuredContent: structured
    )
}

/// Build the setup package if configured. Returns nil if no setup or standalone mode.
private func buildSetupIfConfigured(
    config: ProjectConfig?,
    configDirectory: URL?,
    platform: PreviewPlatform
) async throws -> SetupBuilder.Result? {
    guard let setupConfig = config?.setup, let configDir = configDirectory else { return nil }
    return try await SetupBuilder.build(
        config: setupConfig, configDirectory: configDir, platform: platform
    )
}

/// Resolve the config quality default for a session (iOS or macOS).
private func configQualityForSession(_ sessionID: String) async -> Double? {
    if let iosSession = await iosState.getSession(sessionID) {
        return await configCache.load(for: iosSession.sourceFile)?.config.quality
    }
    if let macSession: PreviewSession = await MainActor.run(body: { host.session(for: sessionID) }) {
        return await configCache.load(for: macSession.sourceFile)?.config.quality
    }
    return nil
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
    let setupDylibPath = setupResult?.dylibPath

    await MainActor.run {
        do {
            try host.loadPreview(
                sessionID: sessionID,
                dylibPath: compileResult.dylibPath,
                title: title,
                size: NSSize(width: width, height: height),
                headless: headless,
                setupDylibPath: setupDylibPath
            )
            host.watchFile(
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

    let configQuality = await configQualityForSession(sessionID)
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

    // macOS path. Verify existence upfront so a typo'd sessionID
    // surfaces as a clean "No session found" rather than the misleading
    // "capture failed" from `window(for:)` returning nil.
    let isMacOSSession = await MainActor.run {
        host.allSessions[sessionID] != nil
    }
    guard isMacOSSession else {
        return CallTool.Result(
            content: [.text("No session found for \(sessionID).")],
            isError: true
        )
    }

    try await Task.sleep(for: .milliseconds(300))

    let format: Snapshot.ImageFormat = usePNG ? .png : .jpeg(quality: quality)
    let imageData: Data = try await MainActor.run {
        guard let window = host.window(for: sessionID) else {
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

    // macOS path. Verify existence before calling `closePreview` — which
    // otherwise silently succeeds for unknown IDs — so typos and races
    // surface as real errors rather than phantom successes.
    let isMacOSSession = await MainActor.run {
        host.allSessions[sessionID] != nil
    }
    guard isMacOSSession else {
        return CallTool.Result(
            content: [.text("No session found for \(sessionID).")],
            isError: true
        )
    }

    await MainActor.run {
        host.closePreview(sessionID: sessionID)
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

    // Parse WDA's JSON into a `Value` so the structured payload carries
    // the tree natively rather than as an opaque string. The text block
    // keeps the raw JSON for agents that don't consume
    // `structuredContent`.
    let structured: Value?
    if let data = elementsJSON.data(using: .utf8),
        let tree = try? JSONDecoder().decode(Value.self, from: data)
    {
        structured = .object([
            "sessionID": .string(sessionID),
            "elements": tree,
        ])
    } else {
        structured = nil
    }

    return CallTool.Result(
        content: [.text(elementsJSON)],
        structuredContent: structured
    )
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
    let manager = await iosState.simulatorManager
    let devices = try await manager.listDevices()
    let available = devices.filter { $0.isAvailable }

    let structured = DaemonProtocol.SimulatorListResult(
        simulators: available.map { device in
            DaemonProtocol.SimulatorDTO(
                udid: device.udid,
                name: device.name,
                runtime: device.runtimeName,
                state: device.stateString,
                isAvailable: device.isAvailable
            )
        }
    )

    if available.isEmpty {
        return try CallTool.Result(
            content: [.text("No available simulator devices found.")],
            structuredContent: structured
        )
    }

    var lines: [String] = []
    for device in available {
        let state = device.state == .booted ? " [BOOTED]" : ""
        lines.append("\(device.name) — \(device.udid)\(state) (\(device.runtimeName ?? "unknown runtime"))")
    }

    return try CallTool.Result(
        content: [.text(lines.joined(separator: "\n"))],
        structuredContent: structured
    )
}

/// List all active sessions (iOS + macOS). Output is one line per session in
/// the format `<sessionID>\t<platform>\t<sourceFilePath>` — tab-delimited for
/// simple client-side parsing. Empty result when no sessions are active.
private func handleSessionList() async -> CallTool.Result {
    var sessions: [DaemonProtocol.SessionDTO] = []

    let iosSessions = await iosState.allSessionsInfo()
    for session in iosSessions {
        sessions.append(
            DaemonProtocol.SessionDTO(
                sessionID: session.id,
                platform: "ios",
                sourceFilePath: session.sourceFile.path
            )
        )
    }

    let macSessions = await MainActor.run { host?.allSessions ?? [:] }
    for (id, session) in macSessions {
        sessions.append(
            DaemonProtocol.SessionDTO(
                sessionID: id,
                platform: "macos",
                sourceFilePath: session.sourceFile.path
            )
        )
    }

    // Stable ordering so clients parsing the output get consistent results.
    sessions.sort { $0.sessionID < $1.sessionID }
    let lines = sessions.map { "\($0.sessionID)\t\($0.platform)\t\($0.sourceFilePath)" }

    // An empty lines array joins to "" — matches the legacy "no active
    // sessions" response that SessionResolver.parseSessionList handles.
    let textBlock: [Tool.Content] = [.text(lines.joined(separator: "\n"))]

    // Use do/try and fall back to the text-only response if Codable
    // encoding somehow throws; handleSessionList is non-throwing so we
    // can't propagate. Encoding [SessionDTO] is trivial and won't fail
    // in practice.
    do {
        return try CallTool.Result(
            content: textBlock,
            structuredContent: DaemonProtocol.SessionListResult(sessions: sessions)
        )
    } catch {
        return CallTool.Result(content: textBlock)
    }
}

// MARK: - Trait Helpers

/// Parse and validate trait parameters. Returns (traits, clearedFields, nil) on
/// success or (default traits, [], error result) on failure. Callers should
/// check the last element first; the other values are meaningless on error.
///
/// `clearedFields` names the fields the client explicitly passed as an empty
/// string (the "clear this trait" signal documented in the MCP tool schema).
/// Without this, empty strings would be indistinguishable from absent fields
/// after `PreviewTraits.validated` normalizes them to nil.
private func parseTraits(
    from params: CallTool.Parameters
) -> (PreviewTraits, Set<PreviewTraits.Field>, CallTool.Result?) {
    let cleared = clearedTraitFields(in: params)
    do {
        let traits = try PreviewTraits.validated(
            colorScheme: extractOptionalString("colorScheme", from: params),
            dynamicTypeSize: extractOptionalString("dynamicTypeSize", from: params),
            locale: extractOptionalString("locale", from: params),
            layoutDirection: extractOptionalString("layoutDirection", from: params),
            legibilityWeight: extractOptionalString("legibilityWeight", from: params)
        )
        return (traits, cleared, nil)
    } catch {
        return (
            PreviewTraits(), [],
            CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        )
    }
}

/// Returns the set of trait fields that the client passed as an empty string
/// ("" — the documented clear signal). Does not touch fields that were absent
/// from the params entirely.
private func clearedTraitFields(
    in params: CallTool.Parameters
) -> Set<PreviewTraits.Field> {
    var cleared: Set<PreviewTraits.Field> = []
    for field in PreviewTraits.Field.allCases {
        if case .string("") = params.arguments?[field.rawValue] {
            cleared.insert(field)
        }
    }
    return cleared
}

private func handlePreviewConfigure(params: CallTool.Parameters, server: Server) async throws -> CallTool.Result {
    let sessionID: String
    do { sessionID = try extractString("sessionID", from: params) } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    // Parse and validate traits
    let (traits, clearedFields, validationError) = parseTraits(from: params)
    if let validationError { return validationError }

    // "No-op" = no fields were set AND no fields were requested to be cleared.
    if traits.isEmpty && clearedFields.isEmpty {
        return CallTool.Result(content: [.text("No configuration changes specified.")])
    }

    let progress = mcpReporter(server: server, params: params, totalSteps: 1)

    // iOS path
    if let iosSession = await iosState.getSession(sessionID) {
        await progress.report(.compilingBridge, message: "Recompiling with new traits...")
        try await iosSession.reconfigure(traits: traits, clearing: clearedFields)
        let activeTraits = await iosSession.currentTraits
        return CallTool.Result(content: [
            .text(
                "Configured session \(sessionID): \(traitsSummary(activeTraits)). View recompiled (@State was reset)."
            )
        ])
    }

    // macOS path
    let session: PreviewSession? = await MainActor.run { host.session(for: sessionID) }
    guard let session else {
        return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
    }

    await progress.report(.compilingBridge, message: "Recompiling with new traits...")
    let compileResult = try await session.reconfigure(
        traits: traits, clearing: clearedFields
    )
    try await MainActor.run {
        try host.loadPreview(sessionID: sessionID, dylibPath: compileResult.dylibPath)
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

/// Capture a screenshot under each of N trait configurations.
///
/// **Concurrent-modification caveat:** `PreviewSession` is an actor so
/// its state transitions are serialized, but a second client calling
/// `preview_configure` or `preview_switch` against the same session
/// while variants is mid-loop will interleave its trait changes into
/// our capture stream — subsequent variant screenshots would reflect
/// the other client's mutation. The daemon does not hold a per-session
/// lock across tool calls. Callers that want deterministic variants
/// should ensure they own the session for the duration.
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

    let variantConfigQuality = await configQualityForSession(sessionID)
    let quality = max(0.0, min(1.0, extractOptionalDouble("quality", from: params) ?? variantConfigQuality ?? 0.85))
    let usePNG = quality >= 1.0
    let mimeType = usePNG ? "image/png" : "image/jpeg"
    let progress = mcpReporter(server: server, params: params, totalSteps: 2 * resolved.count)

    // iOS path
    if let iosSession = await iosState.getSession(sessionID) {
        let savedTraits = await iosSession.currentTraits
        var contentBlocks: [Tool.Content] = []
        var outcomes: [DaemonProtocol.VariantOutcomeDTO] = []
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
                // imageIndex addresses the .image block we just appended.
                outcomes.append(
                    DaemonProtocol.VariantOutcomeDTO(
                        status: "ok",
                        index: index,
                        label: variant.label,
                        imageIndex: contentBlocks.count - 1,
                        error: nil
                    )
                )
            } catch {
                failCount += 1
                contentBlocks.append(
                    .text("[\(index)] \(variant.label): ERROR — \(error.localizedDescription)"))
                outcomes.append(
                    DaemonProtocol.VariantOutcomeDTO(
                        status: "error",
                        index: index,
                        label: variant.label,
                        imageIndex: nil,
                        error: error.localizedDescription
                    )
                )
            }
        }

        // Restore original traits if they changed — but only if the
        // session is still registered. A concurrent `preview_stop`
        // during the capture loop will remove the session from
        // iosState; attempting to setTraits on the stopped simulator
        // produces a misleading "failed to restore" warning when the
        // user explicitly asked for the stop.
        let stillRegistered = await iosState.getSession(sessionID) != nil
        let currentTraits = await iosSession.currentTraits
        if stillRegistered, savedTraits != currentTraits {
            do {
                try await iosSession.setTraits(savedTraits)
            } catch {
                contentBlocks.append(
                    .text("Warning: failed to restore original traits: \(error.localizedDescription)")
                )
            }
        }

        let structured = DaemonProtocol.VariantsResult(
            variants: outcomes,
            successCount: outcomes.count - failCount,
            failCount: failCount
        )
        return try CallTool.Result(
            content: contentBlocks,
            structuredContent: structured,
            isError: failCount == resolved.count
        )
    }

    // macOS path
    let session: PreviewSession? = await MainActor.run { host.session(for: sessionID) }
    guard let session else {
        return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
    }

    let savedTraits = await session.currentTraits
    var contentBlocks: [Tool.Content] = []
    var outcomes: [DaemonProtocol.VariantOutcomeDTO] = []
    var failCount = 0
    let format: Snapshot.ImageFormat = usePNG ? .png : .jpeg(quality: quality)

    for (index, variant) in resolved.enumerated() {
        do {
            await progress.report(
                .compilingBridge, message: "Recompiling for variant \"\(variant.label)\"...")
            let compileResult = try await session.setTraits(variant.traits)
            try await MainActor.run {
                try host.loadPreview(sessionID: sessionID, dylibPath: compileResult.dylibPath)
            }
            try await Task.sleep(for: .milliseconds(300))
            await progress.report(
                .capturingSnapshot,
                message: "Capturing variant \(index + 1)/\(resolved.count) \"\(variant.label)\"...")
            let imageData: Data = try await MainActor.run {
                guard let window = host.window(for: sessionID) else {
                    throw SnapshotError.captureFailed
                }
                return try Snapshot.capture(window: window, format: format)
            }
            let base64 = imageData.base64EncodedString()
            contentBlocks.append(.text("[\(index)] \(variant.label):"))
            contentBlocks.append(.image(data: base64, mimeType: mimeType, metadata: nil))
            outcomes.append(
                DaemonProtocol.VariantOutcomeDTO(
                    status: "ok",
                    index: index,
                    label: variant.label,
                    imageIndex: contentBlocks.count - 1,
                    error: nil
                )
            )
        } catch {
            failCount += 1
            contentBlocks.append(
                .text("[\(index)] \(variant.label): ERROR — \(error.localizedDescription)"))
            outcomes.append(
                DaemonProtocol.VariantOutcomeDTO(
                    status: "error",
                    index: index,
                    label: variant.label,
                    imageIndex: nil,
                    error: error.localizedDescription
                )
            )
        }
    }

    // Restore original traits if they changed — but only if the
    // session is still registered. A concurrent `preview_stop` during
    // the capture loop would remove the session from host;
    // `loadPreview` would then throw and the user would see a
    // misleading "failed to restore" warning when they explicitly
    // asked for the stop.
    let stillRegistered = await MainActor.run {
        host.allSessions[sessionID] != nil
    }
    let currentTraits = await session.currentTraits
    if stillRegistered, savedTraits != currentTraits {
        do {
            let restoreResult = try await session.setTraits(savedTraits)
            try await MainActor.run {
                try host.loadPreview(sessionID: sessionID, dylibPath: restoreResult.dylibPath)
            }
        } catch {
            contentBlocks.append(
                .text("Warning: failed to restore original traits: \(error.localizedDescription)"))
        }
    }

    let structured = DaemonProtocol.VariantsResult(
        variants: outcomes,
        successCount: outcomes.count - failCount,
        failCount: failCount
    )
    return try CallTool.Result(
        content: contentBlocks,
        structuredContent: structured,
        isError: failCount == resolved.count
    )
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
        // Bounds-check before delegating. The compile path will also
        // validate (PreviewSession.compile throws previewNotFound) but
        // an early structured error guarantees a fast, deterministic
        // failure regardless of any upstream transport state. See #127.
        let previews = try PreviewParser.parse(fileAt: iosSession.sourceFile)
        if let outOfRange = previewIndexOutOfRangeError(newIndex, count: previews.count) {
            return outOfRange
        }
        await progress.report(.compilingBridge, message: "Switching to preview \(newIndex)...")
        try await iosSession.switchPreview(to: newIndex)
        let activeTraits = await iosSession.currentTraits
        let traitInfo = activeTraits.isEmpty ? "" : " Traits: \(traitsSummary(activeTraits))."

        let previewList = formatPreviewList(previews: previews, activeIndex: newIndex)
        let structured = DaemonProtocol.SwitchResult(
            sessionID: sessionID,
            activeIndex: newIndex,
            traits: DaemonProtocol.TraitsDTO.orNil(activeTraits),
            previews: previews.map {
                DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: newIndex)
            }
        )
        return try CallTool.Result(
            content: [
                .text(
                    "Switched to preview \(newIndex) in session \(sessionID).\(traitInfo) View recompiled (@State was reset).\n\(previewList)"
                )
            ],
            structuredContent: structured
        )
    }

    // macOS path
    let session: PreviewSession? = await MainActor.run { host.session(for: sessionID) }
    guard let session else {
        return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
    }

    let previews = try PreviewParser.parse(fileAt: session.sourceFile)
    if let outOfRange = previewIndexOutOfRangeError(newIndex, count: previews.count) {
        return outOfRange
    }

    await progress.report(.compilingBridge, message: "Switching to preview \(newIndex)...")
    let compileResult = try await session.switchPreview(to: newIndex)
    try await MainActor.run {
        try host.loadPreview(sessionID: sessionID, dylibPath: compileResult.dylibPath)
    }

    let activeTraits = await session.currentTraits
    let traitInfo = activeTraits.isEmpty ? "" : " Traits: \(traitsSummary(activeTraits))."

    let previewList = formatPreviewList(previews: previews, activeIndex: newIndex)
    let structured = DaemonProtocol.SwitchResult(
        sessionID: sessionID,
        activeIndex: newIndex,
        traits: DaemonProtocol.TraitsDTO.orNil(activeTraits),
        previews: previews.map {
            DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: newIndex)
        }
    )
    return try CallTool.Result(
        content: [
            .text(
                "Switched to preview \(newIndex) in session \(sessionID).\(traitInfo) View recompiled (@State was reset).\n\(previewList)"
            )
        ],
        structuredContent: structured
    )
}

/// Validate `previewIndex` against the parsed preview count. Returns a
/// structured error result if out of range, or `nil` if the index is
/// valid. Centralized so the iOS and macOS switch paths return identical
/// error messages — `SwitchCommandTests.switchOutOfRange` asserts on the
/// exact "out of range" substring.
private func previewIndexOutOfRangeError(_ newIndex: Int, count: Int) -> CallTool.Result? {
    guard newIndex < 0 || newIndex >= count else { return nil }
    return CallTool.Result(
        content: [
            .text("Preview index \(newIndex) out of range (available: 0..<\(count))")
        ],
        isError: true
    )
}
