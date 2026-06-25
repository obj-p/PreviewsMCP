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
