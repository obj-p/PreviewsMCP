import AppKit
import Foundation
import MCP
import PreviewsCore
import PreviewsEngine
import PreviewsIOS
import PreviewsMacOS

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
                        "Absolute path to a Swift source file containing #Preview"),
                ]),
                "previewIndex": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "0-based index of which #Preview to show (default: 0)"),
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
                    "description": .string(
                        "If false, shows the preview window (default: true)"),
                ]),
                "width": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Window width in points (macOS only, default: 400)"),
                ]),
                "height": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Window height in points (macOS only, default: 600)"),
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
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        Log.info("preview_start: enter")

        let filePath: String
        do { filePath = try extractString("filePath", from: params) } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
        }

        let previewIndex = extractOptionalInt("previewIndex", from: params) ?? 0

        Log.info("preview_start: loading config")
        let configResult = await ctx.configCache.load(for: fileURL)
        Log.info("preview_start: config loaded")
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
        do {
            buildContext = try await detectBuildContext(
                for: fileURL, params: params, platform: .macOS, progress: progress)
        } catch {
            return CallTool.Result(
                content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
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
            host: ctx.host
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
}

private func handleIOSPreviewStart(
    fileURL: URL,
    previewIndex: Int,
    params: CallTool.Parameters,
    configResult: ProjectConfigLoader.Result?,
    traits: PreviewTraits = PreviewTraits(),
    ctx: HandlerContext
) async throws -> CallTool.Result {
    // Stage markers on stderr so CI diagnostic dumps show where a hang
    // occurred before session.start() gets a chance to log anything.
    // Progress reported via `progress` goes over the MCP stdio protocol
    // and is invisible in the captured stderr log.
    func stage(_ s: String) { Log.info("preview_start/ios: \(s)") }
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

    stage("getting compiler")
    let iosCompiler = try await ctx.iosState.getCompiler()
    stage("getting hostBuilder")
    let hostBuilder = try await ctx.iosState.getHostBuilder()
    stage("getting simulatorManager")
    let simulatorManager = await ctx.iosState.simulatorManager

    let headless = extractOptionalBool("headless", from: params) ?? true

    // Detect build system
    let progress = mcpReporter(server: ctx.server, params: params, totalSteps: 8)
    let buildContext: BuildContext?
    do {
        stage("detectBuildContext begin")
        buildContext = try await detectBuildContext(for: fileURL, params: params, platform: .iOS, progress: progress)
        stage("detectBuildContext done (\(buildContext == nil ? "nil" : "ok"))")
    } catch {
        stage("detectBuildContext failed: \(error)")
        return CallTool.Result(content: [.text("Project build failed: \(error.localizedDescription)")], isError: true)
    }

    stage("buildSetupIfConfigured begin")
    let setupResult = try await buildSetupIfConfigured(
        config: config, configDirectory: configResult?.directory, platform: .iOS)
    stage("buildSetupIfConfigured done (\(setupResult == nil ? "nil" : "ok"))")

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

    stage("session.start begin")
    let pid = try await session.start()
    stage("session.start done pid=\(pid)")
    await ctx.iosState.addSession(session)

    // Set up file watching for hot-reload
    let sessionID = session.id
    let allPaths = [fileURL.path] + (buildContext?.sourceFiles?.map(\.path) ?? [])
    let iosState = ctx.iosState
    let watcher = try? FileWatcher(paths: allPaths) {
        Task {
            Log.info("MCP: iOS file change detected, reloading session \(sessionID)...")
            do {
                let wasLiteralOnly = try await session.handleSourceChange()
                if wasLiteralOnly {
                    Log.info("MCP: iOS literal-only change applied (state preserved)")
                } else {
                    Log.info("MCP: iOS structural change — recompiled and signalled reload")
                }
            } catch {
                Log.error("MCP: iOS reload failed for session \(sessionID): \(error)")
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

private func startMacOSPreview(
    fileURL: URL, previewIndex: Int, title: String,
    width: Int, height: Int,
    compiler: Compiler, buildContext: BuildContext?,
    traits: PreviewTraits = PreviewTraits(),
    setupResult: SetupBuilder.Result? = nil,
    headless: Bool = true,
    host: PreviewHost
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
            Log.error("MCP: Failed to load preview: \(error)")
        }
    }

    return sessionID
}
