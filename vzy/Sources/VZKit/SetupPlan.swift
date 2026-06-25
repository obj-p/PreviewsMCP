import CoreGraphics
import Foundation

public struct ScreenRule: Sendable {
    public let match: String
    public let actions: [SetupAssistantSequence.Step]
    public let terminal: Bool

    public init(match: String, actions: [SetupAssistantSequence.Step], terminal: Bool) {
        self.match = match
        self.actions = actions
        self.terminal = terminal
    }
}

public struct SetupPlan: Codable, Sendable {
    public var maxIterations: Int?
    public var settleSeconds: Double?
    public var rules: [Rule]

    public struct Rule: Codable, Sendable {
        public var match: String
        public var terminal: Bool?
        public var actions: [Action]
    }

    public struct Action: Codable, Sendable {
        public var op: String
        public var text: String?
        public var seconds: Double?
        public var key: String?
        public var modifier: String?
        public var label: String?
    }

    public static func load(from url: URL) throws -> SetupPlan {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SetupPlan.self, from: data)
    }

    public func screenRules() throws -> [ScreenRule] {
        try rules.map { rule in
            ScreenRule(
                match: rule.match,
                actions: try rule.actions.map { try $0.step() },
                terminal: rule.terminal ?? false
            )
        }
    }
}

extension SetupPlan.Action {
    func step() throws -> SetupAssistantSequence.Step {
        switch op {
        case "wait":
            return .wait(seconds: seconds ?? 1)
        case "type":
            return .type(try require(text, "text"))
        case "clickByText":
            return .clickByText(try require(text, "text"))
        case "verifyText":
            return .verifyText(try require(text, "text"))
        case "screenshot":
            return .screenshot(label: label ?? "screen")
        case "key":
            return .key(try Self.parseKey(require(key, "key")))
        case "modifiedKey":
            return .modifiedKey(
                modifier: try Self.parseModifier(require(modifier, "modifier")),
                key: try Self.parseKey(require(key, "key"))
            )
        default:
            throw VMError("unknown plan action op: \(op)")
        }
    }

    private func require(_ value: String?, _ name: String) throws -> String {
        guard let value else { throw VMError("plan action \(op) missing field \(name)") }
        return value
    }

    static func parseKey(_ name: String) throws -> KeyboardScripter.Key {
        switch name {
        case "tab": return .tab
        case "return": return .returnKey
        case "space": return .space
        case "escape": return .escape
        case "delete": return .delete
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        default: throw VMError("unknown key: \(name)")
        }
    }

    static func parseModifier(_ name: String) throws -> SetupAssistantSequence.Modifier {
        switch name {
        case "shift": return .shift
        case "command": return .command
        case "option": return .option
        case "control": return .control
        default: throw VMError("unknown modifier: \(name)")
        }
    }
}

extension SetupAssistantSequence {
    public static func runDispatchVNC(
        rules: [ScreenRule],
        host: FirstBootHost,
        client: RFBClient,
        screenshotDir: URL?,
        maxIterations: Int = 60,
        settleSeconds: Double = 2
    ) async throws {
        if let screenshotDir {
            try FileManager.default.createDirectory(
                at: screenshotDir, withIntermediateDirectories: true
            )
        }
        let framebuffer = CGSize(width: 1280, height: 720)
        let persistLimit = 20
        let blankLimit = 30
        var lastMatch: String?
        var persistCount = 0
        var noMatchCount = 0
        var blankCount = 0

        for iteration in 0 ..< maxIterations {
            let observations = try await ocrScreen(host: host, framebufferSize: framebuffer)
            if let screenshotDir {
                let url = screenshotDir.appending(
                    path: String(format: "iter-%02d.png", iteration)
                )
                try? await MainActor.run {
                    try Screenshot.captureWindow(host.window, to: url)
                }
            }

            guard let rule = rules.first(where: {
                FramebufferOCR.find($0.match, in: observations) != nil
            }) else {
                if observations.isEmpty {
                    blankCount += 1
                    if blankCount >= blankLimit {
                        throw VMError(
                            "dispatch: framebuffer stayed blank for \(blankCount) iterations"
                        )
                    }
                } else {
                    noMatchCount += 1
                    if noMatchCount >= 5 {
                        let seen = observations.prefix(20).map { $0.text }
                        throw VMError(
                            "dispatch: no rule matched the current screen. " +
                                "Saw: \(seen.joined(separator: " | "))"
                        )
                    }
                }
                try await Task.sleep(for: .seconds(settleSeconds))
                continue
            }
            blankCount = 0
            noMatchCount = 0

            if rule.match == lastMatch {
                persistCount += 1
                if persistCount >= persistLimit {
                    throw VMError(
                        "dispatch: screen \"\(rule.match)\" did not advance"
                    )
                }
                try await Task.sleep(for: .seconds(settleSeconds))
                continue
            }

            lastMatch = rule.match
            persistCount = 0
            Log.info("[dispatch iter \(iteration)] matched \"\(rule.match)\"")
            try await runVNC(
                rule.actions, host: host, client: client, screenshotDir: nil
            )

            if rule.terminal {
                Log.info("[dispatch] terminal screen reached")
                return
            }
            try await Task.sleep(for: .seconds(settleSeconds))
        }
        throw VMError(
            "dispatch: exceeded \(maxIterations) iterations without a terminal screen"
        )
    }

    private static func ocrScreen(
        host: FirstBootHost,
        framebufferSize: CGSize
    ) async throws -> [FramebufferOCR.Observation] {
        let tempImage = FileManager.default.temporaryDirectory
            .appending(path: "vz-dispatch-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempImage) }
        try await MainActor.run {
            try Screenshot.captureContentView(host.view, to: tempImage)
        }
        return try FramebufferOCR.recognize(
            imageURL: tempImage, framebufferSize: framebufferSize
        )
    }
}
