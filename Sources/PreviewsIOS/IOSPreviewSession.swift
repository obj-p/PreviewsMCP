import Foundation
import PreviewsCore

/// Orchestrates the full iOS preview pipeline:
/// boot simulator → install host app → compile dylib → launch → screenshot.
public actor IOSPreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public nonisolated let previewIndex: Int
    public nonisolated let deviceUDID: String

    private let compiler: Compiler
    private let hostBuilder: IOSHostBuilder
    private let simulatorManager: SimulatorManager

    private var signalFilePath: URL?
    private var literalsFilePath: URL?
    private var touchFilePath: URL?
    private var elementsFilePath: URL?
    private var session: PreviewSession?
    public nonisolated let headless: Bool
    private let buildContext: BuildContext?

    public static let hostBundleID = "com.previewsmcp.host"

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        deviceUDID: String,
        compiler: Compiler,
        hostBuilder: IOSHostBuilder,
        simulatorManager: SimulatorManager,
        headless: Bool = true,
        buildContext: BuildContext? = nil
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
    }

    /// Start the iOS preview: compile, boot sim, install host, launch.
    /// Returns the PID of the launched host app.
    public func start() async throws -> Int {
        // 1. Compile preview dylib for iOS simulator
        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOSSimulator,
            buildContext: buildContext
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        // 2. Boot simulator and install host app.
        // Retry loop handles transient CoreSimulator daemon issues
        // (Mach error -308, "Shutdown" state races from concurrent operations).
        let appPath = try await hostBuilder.ensureHostApp()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                // Check/boot on every attempt — device may have been shut down externally
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

        // 3b. Open Simulator.app GUI if not headless
        if !headless {
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = ["-a", "Simulator", "--args", "-CurrentDeviceUDID", deviceUDID]
            try? openProcess.run()
            openProcess.waitUntilExit()
        }

        // 4. Create signal files for hot-reload and interaction
        let workDir = compileResult.dylibPath.deletingLastPathComponent()
        let signalFile = workDir.appendingPathComponent("reload-signal.txt")
        let literalsFile = workDir.appendingPathComponent("literals-signal.json")
        let touchFile = workDir.appendingPathComponent("touch-signal.json")
        let elementsFile = workDir.appendingPathComponent("elements-request.json")
        try compileResult.dylibPath.path.write(to: signalFile, atomically: true, encoding: .utf8)
        try "[]".write(to: literalsFile, atomically: true, encoding: .utf8)
        try "{}".write(to: touchFile, atomically: true, encoding: .utf8)
        try "{}".write(to: elementsFile, atomically: true, encoding: .utf8)
        signalFilePath = signalFile
        literalsFilePath = literalsFile
        touchFilePath = touchFile
        elementsFilePath = elementsFile

        // 5. Launch host app with dylib path
        let pid = try await simulatorManager.launchApp(
            udid: deviceUDID,
            bundleID: Self.hostBundleID,
            arguments: [
                "--dylib", compileResult.dylibPath.path,
                "--signal-file", signalFile.path,
                "--literals-file", literalsFile.path,
                "--touch-file", touchFile.path,
                "--elements-file", elementsFile.path,
            ]
        )

        return pid
    }

    /// Handle a source file change. Tries the literal fast path first;
    /// falls back to full recompile if structural changes are detected.
    /// Returns true if the fast path was used.
    @discardableResult
    public func handleSourceChange() async throws -> Bool {
        guard signalFilePath != nil else {
            throw IOSPreviewSessionError.notStarted
        }

        let newSource = try String(contentsOf: sourceFile, encoding: .utf8)

        // Fast path: literal-only change
        if let currentSession = session,
           let changes = await currentSession.tryLiteralUpdate(newSource: newSource),
           !changes.isEmpty,
           let literalsFile = literalsFilePath {
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
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: literalsFile, options: .atomic)
            return true
        }

        // Slow path: structural change, full recompile
        try await reload()
        return false
    }

    /// Recompile the preview and signal the running host app to reload.
    public func reload() async throws {
        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOSSimulator,
            buildContext: buildContext
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        guard let signalFile = signalFilePath else {
            throw IOSPreviewSessionError.notStarted
        }
        try compileResult.dylibPath.path.write(to: signalFile, atomically: true, encoding: .utf8)
    }

    /// Send a tap at the given point coordinates (in device points).
    /// Fully headless via in-app IOHIDEvent + BKSHIDEvent injection.
    public func sendTap(x: Double, y: Double) async throws {
        try sendTouchCommand(["action": "tap", "x": x, "y": y])
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Send a swipe gesture from one point to another.
    /// Duration in seconds, steps controls smoothness.
    public func sendSwipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        duration: Double = 0.3,
        steps: Int = 10
    ) async throws {
        try sendTouchCommand([
            "action": "swipe",
            "fromX": fromX, "fromY": fromY,
            "toX": toX, "toY": toY,
            "duration": duration, "steps": steps,
        ])
        // Wait for swipe to complete + processing
        try await Task.sleep(for: .milliseconds(Int(duration * 1000) + 200))
    }

    private func sendTouchCommand(_ command: [String: Any]) throws {
        guard let touchFile = touchFilePath else {
            throw IOSPreviewSessionError.notStarted
        }
        let data = try JSONSerialization.data(withJSONObject: command)
        try data.write(to: touchFile, options: .atomic)
    }

    /// Fetch the accessibility tree from the running preview.
    /// Returns JSON describing all accessible elements with their frames and labels.
    /// - Parameter filter: Filter mode: "all" (default), "interactable", or "labeled"
    public func fetchElements(filter: String = "all") async throws -> String {
        guard let elementsFile = elementsFilePath else {
            throw IOSPreviewSessionError.notStarted
        }

        let responseFile = elementsFile.deletingLastPathComponent()
            .appendingPathComponent("elements-response.json")

        // Remove stale response
        try? FileManager.default.removeItem(at: responseFile)

        // Write request — host app watches this file and writes response
        let request: [String: Any] = ["action": "dump", "responsePath": responseFile.path]
        let data = try JSONSerialization.data(withJSONObject: request)
        try data.write(to: elementsFile, options: .atomic)

        // Poll for response (up to 2 seconds)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            if FileManager.default.fileExists(atPath: responseFile.path) {
                let rawJSON = try String(contentsOf: responseFile, encoding: .utf8)

                guard filter != "all" else { return rawJSON }

                // Apply server-side filtering
                guard let jsonData = rawJSON.data(using: .utf8),
                      let tree = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let filtered = filterTree(tree, mode: filter),
                      let filteredData = try? JSONSerialization.data(withJSONObject: filtered),
                      let filteredJSON = String(data: filteredData, encoding: .utf8) else {
                    return rawJSON
                }
                return filteredJSON
            }
        }

        throw IOSPreviewSessionError.elementsTimeout
    }

    /// Recursively filter the accessibility tree, keeping only nodes that match the filter mode.
    /// Container nodes are kept if they have matching descendants.
    private func filterTree(_ node: [String: Any], mode: String) -> [String: Any]? {
        let children = node["children"] as? [[String: Any]]

        if children == nil || children!.isEmpty {
            // Leaf node — apply filter
            return matchesFilter(node, mode: mode) ? node : nil
        }

        // Container node — recurse and keep branches with matching descendants
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

    /// Check whether a leaf node matches the given filter mode.
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

    /// Capture a screenshot of the simulator.
    public func screenshot() async throws -> Data {
        return try await simulatorManager.screenshotData(udid: deviceUDID)
    }
}

public enum IOSPreviewSessionError: Error, LocalizedError, CustomStringConvertible {
    case notStarted
    case elementsTimeout

    public var description: String {
        switch self {
        case .notStarted: return "iOS preview session has not been started"
        case .elementsTimeout: return "Timed out waiting for accessibility tree response"
        }
    }

    public var errorDescription: String? { description }
}
