import AppKit
import Foundation
import MCP
import PreviewsCore
import PreviewsEngine
import PreviewsIOS
import PreviewsJITLink
import PreviewsMacOS

/// Builds the iOS JIT reloader from the accepted EPC fd. Mirrors the macOS
/// `host.makeStructuralReloader` injection in `PreviewsMCPApp`.
private let iosJITReloaderFactory: IOSPreviewSession.MakeJITReloader = { fd, orcPath in
    try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
}

enum PreviewStartHandler: ToolHandler {
    static let name: ToolName = .previewStart

    static let schema = Tool(
        name: ToolName.previewStart.rawValue,
        description:
        "Compile and launch a live SwiftUI preview. Returns a session ID. Supports macOS (default) and iOS simulator.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "filePath": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Absolute path to a Swift source file containing #Preview"
                    ),
                ]),
                "previewIndex": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "0-based index of which #Preview to show (default: 0)"
                    ),
                ]),
                "platform": .object([
                    "type": .string("string"),
                    "description": .string("Target platform: 'macos' (default) or 'ios'"),
                ]),
                "deviceUDID": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Simulator device UDID (for ios; auto-selects if omitted)"
                    ),
                ]),
                "headless": .object([
                    "type": .string("boolean"),
                    "description": .string(
                        "If false, shows the preview window (default: true)"
                    ),
                ]),
                "width": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Window width in points (macOS only, default: 400)"
                    ),
                ]),
                "height": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Window height in points (macOS only, default: 600)"
                    ),
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
                "buildSystem": .object([
                    "type": .string("string"),
                    "enum": .array(BuildSystemKind.allCases.map { .string($0.rawValue) }),
                    "description": .string(
                        "Force the build system instead of auto-detecting by project markers (spm, bazel, xcode). Useful when a project matches more than one, e.g. a rules_xcodeproj workspace that has both MODULE.bazel and a generated .xcodeproj."
                    ),
                ]),
                "colorScheme": traitProperty(
                    enumValues: PreviewTraits.validColorSchemes,
                    description: "Color scheme override: 'light' or 'dark'"
                ),
                "dynamicTypeSize": traitProperty(
                    enumValues: PreviewTraits.validDynamicTypeSizes,
                    description: "Dynamic Type size (e.g., 'large', 'accessibility3')"
                ),
                "locale": traitProperty(
                    description: "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP')"
                ),
                "layoutDirection": traitProperty(
                    enumValues: PreviewTraits.validLayoutDirections,
                    description: "Layout direction: 'leftToRight' or 'rightToLeft'"
                ),
                "legibilityWeight": traitProperty(
                    enumValues: PreviewTraits.validLegibilityWeights,
                    description: "Legibility weight: 'regular' or 'bold' (Bold Text accessibility)"
                ),
                "config": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Path to a .previewsmcp.json config file. When omitted, the daemon auto-discovers by walking up from the source file's directory."
                    ),
                ]),
            ]),
            "required": .array([.string("filePath")]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        Log.info("preview_start: enter")

        let rawFilePath: String
        do { rawFilePath = try extractString("filePath", from: params) } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        let fileURL = Path.normalizeURL(rawFilePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CallTool.Result(content: [.text("File not found: \(rawFilePath)")], isError: true)
        }

        let previewIndex = extractOptionalInt("previewIndex", from: params) ?? 0

        Log.info("preview_start: loading config")
        let configResult = loadProjectConfig(
            explicit: extractOptionalString("config", from: params), fileURL: fileURL
        )
        Log.info("preview_start: config loaded")
        let config = configResult?.config
        let platformStr: String = if let explicit = extractOptionalString("platform", from: params) {
            explicit
        } else if let configPlatform = config?.platform {
            configPlatform
        } else if await SPMBuildSystem.inferredPlatformAsync(for: fileURL) == .iOS {
            "ios"
        } else {
            "macos"
        }

        // preview_start ignores clearedFields — traits start from empty so there's
        // nothing to clear. Only preview_configure treats clearing meaningfully.
        let (explicitTraits, _, traitsError) = parseTraits(from: params)
        if let traitsError { return traitsError }
        let configTraits = config?.traits?.toPreviewTraits() ?? PreviewTraits()
        let resolvedTraits = configTraits.merged(with: explicitTraits)

        Log.info("preview_start: platform=\(platformStr)")

        // iOS simulator path
        if platformStr == "ios" {
            return try await handleIOSPreviewStart(
                fileURL: fileURL,
                previewIndex: previewIndex,
                params: params,
                configResult: configResult,
                traits: resolvedTraits,
                ctx: ctx
            )
        }

        // macOS path (default)
        let width = extractOptionalInt("width", from: params) ?? 400
        let height = extractOptionalInt("height", from: params) ?? 600
        let headless = extractOptionalBool("headless", from: params) ?? true

        // Detect build system (auto-detect or explicit projectPath)
        let progress = mcpReporter(server: ctx.server, params: params, totalSteps: 3)
        let buildContext: BuildContext?
        let rebuild: @Sendable () async throws -> BuildContext?
        do {
            (buildContext, rebuild) = try await detectBuildContext(
                for: fileURL, params: params, platform: .macOS, progress: progress
            )
        } catch {
            return CallTool.Result(
                content: [.text("Project build failed: \(error.localizedDescription)")], isError: true
            )
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
            compiler: ctx.macCompiler, buildContext: buildContext,
            traits: resolvedTraits,
            setupResult: setupResult,
            headless: headless,
            host: ctx.host,
            refresh: rebuild
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
            setupWarning: standaloneSetupWarning.isEmpty ? nil : standaloneSetupWarning,
            appServerPort: nil
        )
        return try CallTool.Result(
            content: [
                .text(
                    "macOS preview started. Session ID: \(sessionID).\(traitInfo)\(standaloneSetupWarning) File is being watched for changes.\n\(previewList)\(switchHint)"
                ),
            ],
            structuredContent: structured
        )
    }
}

private func handleIOSPreviewStart(
    fileURL: URL,
    previewIndex: Int,
    params: CallTool.Parameters,
    configResult: ProjectConfigLoader.Result?,
    traits: PreviewTraits = PreviewTraits(),
    ctx: HandlerContext
) async throws -> CallTool.Result {
    /// Stage markers on stderr so CI diagnostic dumps show where a hang
    /// occurred before session.start() gets a chance to log anything.
    /// Progress reported via `progress` goes over the MCP stdio protocol
    /// and is invisible in the captured stderr log.
    func stage(_ s: String) {
        Log.info("preview_start/ios: \(s)")
    }
    stage("enter")

    let config = configResult?.config
    // Resolve device UDID — use provided, config, or auto-select
    let deviceUDID: String
    let providedUDID = extractOptionalString("deviceUDID", from: params) ?? config?.device
    do {
        stage("resolving device (provided=\(providedUDID?.prefix(8).description ?? "nil"))")
        deviceUDID = try await resolveDeviceUDID(provided: providedUDID, using: await ctx.iosState.simulatorManager)
        stage("resolved device \(deviceUDID.prefix(8))")
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    // Claim the device before building or launching anything: one live
    // session per device, transferred in order (docs/state-invalidation.md,
    // L01). A live in-process incumbent is stopped and disclosed; a live
    // peer process's session is a classified fail-fast error.
    let claimOwner = UUID().uuidString
    let replacedSessionID: String?
    do {
        stage("claiming device")
        replacedSessionID = try await ctx.iosState.claimDevice(deviceUDID, owner: claimOwner)
        stage("claimed device (replaced=\(replacedSessionID ?? "none"))")
    } catch {
        return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    // One catch spans everything between claim and success: before the
    // claim is confirmed live, a throw releases it (a leaked claim wedges
    // the device forever — waiters have no timeout); after, a throw tears
    // the registered session down, which releases through removeSession.
    var liveSession: IOSPreviewSession?
    do {
        stage("getting compiler")
        let iosCompiler = try await ctx.iosState.getCompiler()
        stage("getting agentBuilder")
        let agentBuilder = try await ctx.iosState.getAgentBuilder()
        stage("getting simulatorManager")
        let simulatorManager = await ctx.iosState.simulatorManager

        let headless = extractOptionalBool("headless", from: params) ?? true

        // Detect build system
        let progress = mcpReporter(server: ctx.server, params: params, totalSteps: 8)
        let buildContext: BuildContext?
        let rebuild: @Sendable () async throws -> BuildContext?
        do {
            stage("detectBuildContext begin")
            (buildContext, rebuild) = try await detectBuildContext(
                for: fileURL, params: params, platform: .iOS, progress: progress
            )
            stage("detectBuildContext done (\(buildContext == nil ? "nil" : "ok"))")
        } catch {
            stage("detectBuildContext failed: \(error)")
            await ctx.iosState.releaseDeviceClaim(deviceUDID, owner: claimOwner)
            return CallTool.Result(
                content: [.text("Project build failed: \(error.localizedDescription)")],
                isError: true
            )
        }

        stage("buildSetupIfConfigured begin")
        let setupResult = try await buildSetupIfConfigured(
            config: config, configDirectory: configResult?.directory, platform: .iOS
        )
        stage("buildSetupIfConfigured done (\(setupResult == nil ? "nil" : "ok"))")

        let session = IOSPreviewSession(
            sourceFile: fileURL,
            previewIndex: previewIndex,
            deviceUDID: deviceUDID,
            compiler: iosCompiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            headless: headless,
            buildContext: buildContext,
            traits: traits,
            setupModule: setupResult?.moduleName,
            setupType: setupResult?.typeName,
            setupCompilerFlags: setupResult?.compilerFlags ?? [],
            setupSDKPath: setupResult?.sdkPath,
            setupDylibPath: setupResult?.dylibPath,
            progress: progress,
            makeJITReloader: iosJITReloaderFactory
        )

        stage("session.start begin")
        let pid = try await session.start()
        stage("session.start done pid=\(pid)")
        await ctx.iosState.addSession(session)

        guard await ctx.iosState.confirmDeviceClaim(
            deviceUDID, owner: claimOwner, sessionID: session.id
        ) else {
            stage("claim lost while launching; tearing down")
            await session.stop()
            await ctx.iosState.removeSession(session.id)
            return CallTool.Result(
                content: [
                    .text(
                        "Session was replaced by a newer preview_start on device \(deviceUDID) while launching."
                    ),
                ], isError: true
            )
        }
        liveSession = session

        // Set up file watching for hot-reload; onEvidenceRefresh reinstalls
        // the watcher from the fresh EvidenceSet after a stage-4 refresh
        // swaps the context.
        let iosState = ctx.iosState
        await session.setRebuildContext(rebuild)
        await session.setOnEvidenceRefresh { [weak session] newContext in
            guard let session else { return }
            await installIOSWatcher(
                session: session, fileURL: fileURL,
                iosState: iosState, buildContext: newContext
            )
        }
        await installIOSWatcher(
            session: session, fileURL: fileURL,
            iosState: iosState, buildContext: buildContext
        )
        let sessionID = session.id

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
            setupWarning: nil,
            appServerPort: (await session.appServerPort).map(Int.init)
        )
        let viewerHint = structured.appServerPort.map {
            "\nInteractive viewer: http://127.0.0.1:\($0)/ — open it in the in-app browser."
        } ?? ""
        return try CallTool.Result(
            content: [
                .text(
                    "iOS simulator preview started on device \(deviceUDID). Session ID: \(sessionID). PID: \(pid).\(traitInfo)\(replacedSessionID.map { " Replaced session \($0) on this device." } ?? "") File is being watched for changes.\n\(previewList)\(switchHint)\(viewerHint)"
                ),
            ],
            structuredContent: structured
        )
    } catch {
        if let liveSession {
            await liveSession.stop()
            await ctx.iosState.removeSession(liveSession.id)
        } else {
            await ctx.iosState.releaseDeviceClaim(deviceUDID, owner: claimOwner)
        }
        throw error
    }
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

/// Install (or reinstall) an iOS session's file watcher from the watch set
/// the build context derives.
private func installIOSWatcher(
    session: IOSPreviewSession, fileURL: URL,
    iosState: IOSSessionManager, buildContext: BuildContext?
) async {
    let sessionID = session.id
    let canonicalPrimary = FileWatcher.canonicalPath(fileURL.path) ?? fileURL.path
    let watchSet = WatchSet.derive(primary: fileURL.path, buildContext: buildContext)
    let watcher = try? FileWatcher(
        paths: watchSet.paths, directories: watchSet.directories
    ) { firedPaths in
        Task {
            Log.info("MCP: iOS file change detected, reloading session \(sessionID)...")
            do {
                try await session.handleSourceChange(
                    firedPaths: firedPaths, canonicalPrimary: canonicalPrimary
                )
                Log.info("MCP: iOS source change — recompiled and re-linked over JIT")
            } catch {
                Log.error("MCP: iOS reload failed for session \(sessionID): \(error)")
            }
        }
    }
    if let watcher {
        await iosState.setFileWatcher(sessionID, watcher)
    }
}

/// Detect and build the project, and return the same detect-and-build —
/// minus progress — as the session's rebuilder for stage-4 refreshes.
private func detectBuildContext(
    for fileURL: URL,
    params: CallTool.Parameters,
    platform: PreviewPlatform,
    progress: (any ProgressReporter)? = nil
) async throws -> (context: BuildContext?, rebuild: @Sendable () async throws -> BuildContext?) {
    let projectRootURL = extractOptionalString("projectPath", from: params)
        .map { Path.normalizeURL($0) }
    let scheme = extractOptionalString("scheme", from: params)
    let buildSystem = try parseBuildSystemOverride(from: params)
    let rebuild: @Sendable () async throws -> BuildContext? = {
        try await detectAndBuild(
            for: fileURL,
            projectRoot: projectRootURL,
            platform: platform,
            scheme: scheme,
            buildSystem: buildSystem
        )
    }
    return (
        try await detectAndBuild(
            for: fileURL,
            projectRoot: projectRootURL,
            platform: platform,
            scheme: scheme,
            buildSystem: buildSystem,
            progress: progress
        ),
        rebuild
    )
}

private func parseBuildSystemOverride(
    from params: CallTool.Parameters
) throws -> BuildSystemKind? {
    guard let raw = extractOptionalString("buildSystem", from: params) else { return nil }
    guard let kind = BuildSystemKind(rawValue: raw) else {
        throw BuildSystemError.buildSystemUnavailable(
            kind: raw,
            reason:
            "unknown build system; valid values: \(BuildSystemKind.allCases.map(\.rawValue).joined(separator: ", "))"
        )
    }
    return kind
}

private func startMacOSPreview(
    fileURL: URL, previewIndex: Int, title: String,
    width: Int, height: Int,
    compiler: Compiler, buildContext: BuildContext?,
    traits: PreviewTraits = PreviewTraits(),
    setupResult: SetupBuilder.Result? = nil,
    headless: Bool = true,
    host: PreviewHost,
    refresh: (@Sendable () async throws -> BuildContext?)? = nil
) async throws -> String {
    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: compiler,
        buildContext: buildContext,
        traits: traits,
        setupModule: setupResult?.moduleName,
        setupType: setupResult?.typeName,
        setupCompilerFlags: setupResult?.compilerFlags ?? [],
        setupSDKPath: setupResult?.sdkPath,
        setupDylibPath: setupResult?.dylibPath
    )

    let sessionID = session.id

    try await host.jitStart(
        sessionID: sessionID, session: session,
        title: title, size: NSSize(width: width, height: height),
        headless: headless
    )
    await MainActor.run {
        host.watchFile(
            sessionID: sessionID,
            session: session,
            filePath: fileURL.path,
            buildContext: buildContext,
            refresh: refresh
        )
    }

    return sessionID
}
