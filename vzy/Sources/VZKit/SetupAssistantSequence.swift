import AppKit
import Foundation

/// Version-pinned wait-and-tab script for Apple's macOS Setup Assistant.
///
/// The sequence is built incrementally — each screen is a list of
/// `Step`s, and the runner executes them in order, optionally taking a
/// screenshot at each named checkpoint. Lots of small
/// `wait → key → wait → key` steps, version-pinned, expected to drift
/// between macOS releases.
///
/// **Brittleness:** SA's flow changes between macOS releases (and
/// occasionally point releases). When this breaks, the fix is to
/// re-screenshot each step and adjust waits/keys. Don't try to make it
/// self-healing — that's a research-grade Vision-Pro problem we don't
/// need.
public enum SetupAssistantSequence {
    /// One unit of work in a script.
    public enum Step: Sendable {
        /// Sleep `seconds` to let the SA UI render / settle.
        case wait(seconds: TimeInterval)
        /// Send a single keystroke.
        case key(KeyboardScripter.Key)
        /// Send `key` with `modifier` held. Modifier keysyms only; the
        /// VNC transport press/releases the modifier around the key.
        /// Used for `Shift+Tab` (focus-Continue trick on macOS 26 SA's
        /// Region screen) and Cmd+letter shortcuts later.
        case modifiedKey(modifier: Modifier, key: KeyboardScripter.Key)
        /// Send a string (each character → key event). ASCII-unshifted only.
        case type(String)
        /// Left-click at `point`. Window coordinates (bottom-left origin)
        /// for the NSEvent runner; framebuffer coordinates (top-left
        /// origin) for the VNC runner. Coords are interpreted by the
        /// runner you call.
        case click(x: Double, y: Double)
        /// OCR-find `text` on the current framebuffer and click its
        /// center. Robust against per-version UI layout changes — the
        /// text is the API; pixel positions are not. Only available
        /// from the VNC runner (NSEvent path is being phased out).
        case clickByText(String)
        /// OCR the current framebuffer; throw if `text` is not present.
        /// Used as a post-condition assertion ("after this step, we
        /// should be on the X screen") so the surrounding retry loop
        /// can restore-and-retry on a missed transition.
        case verifyText(String)
        /// Take a screenshot named `<index>-<label>.png` for inspection.
        case screenshot(label: String)
        /// Free-form log line in the run output.
        case log(String)
        /// Send `key` with two modifiers held simultaneously (e.g.
        /// Cmd+Option+Return to toggle Xcode's preview canvas). VNC
        /// transport only; the NSEvent runner doesn't support modifiers.
        case dualModifiedKey(mod1: Modifier, mod2: Modifier, key: KeyboardScripter.Key)
        /// Run a shell command on the *host* (not the VM) and log its
        /// output. If `expectContains` is non-nil, the step throws if
        /// the command's combined stdout+stderr doesn't contain that
        /// substring. Use this to interleave SSH-driven actions on the
        /// guest with host-side keystroke delivery in a single preset.
        case hostShell(command: String, label: String, expectContains: String? = nil)
        /// Run the screen-dispatch loop over `rules` until a terminal
        /// screen is reached. Clears a variable run of screens (e.g. the
        /// per-user first-login Setup Assistant) whose order isn't known
        /// ahead of time. VNC transport only.
        case dispatch(rules: [ScreenRule], maxIterations: Int)
    }

    public enum Modifier: Sendable {
        case shift
        case command
        case option
        case control
    }
}

extension SetupAssistantSequence {
    /// Execute `steps` against the running `host` over an `RFBClient`
    /// (VNC transport). Screenshots are written into `screenshotDir`
    /// named `<index>-<label>.png`. `click` coordinates are framebuffer
    /// pixels (top-left origin).
    public static func runVNC(
        _ steps: [Step],
        host: FirstBootHost,
        client: RFBClient,
        screenshotDir: URL?
    ) async throws {
        if let screenshotDir {
            try FileManager.default.createDirectory(
                at: screenshotDir, withIntermediateDirectories: true
            )
        }
        var screenshotIndex = 0

        for (stepIndex, step) in steps.enumerated() {
            switch step {
            case let .wait(seconds):
                Log.debug("[SA/VNC step \(stepIndex)] wait \(seconds)s")
                try await Task.sleep(for: .seconds(seconds))

            case let .key(key):
                Log.debug("[SA/VNC step \(stepIndex)] key \(key)")
                try client.tapKey(keysym: keysym(for: key))
                try await Task.sleep(for: .milliseconds(80))

            case let .type(string):
                try await typeStringVNC(string, client: client, stepIndex: stepIndex)

            case let .click(x, y):
                Log.debug("[SA/VNC step \(stepIndex)] click (\(x), \(y))")
                try await leftClickWithHold(
                    client: client,
                    x: UInt16(clamping: Int(x)),
                    y: UInt16(clamping: Int(y))
                )

            case let .verifyText(target):
                try await verifyTextVNC(target, host: host, stepIndex: stepIndex)

            case let .clickByText(target):
                try await clickByTextVNC(target, host: host, client: client, stepIndex: stepIndex)

            case let .modifiedKey(modifier, key):
                Log.debug("[SA/VNC step \(stepIndex)] modifiedKey \(modifier)+\(key)")
                let modKeysym = vncModifierKeysym(modifier)
                let target = keysym(for: key)
                try client.sendKeyEvent(keysym: modKeysym, down: true)
                try client.sendKeyEvent(keysym: target, down: true)
                try client.sendKeyEvent(keysym: target, down: false)
                try client.sendKeyEvent(keysym: modKeysym, down: false)
                try await Task.sleep(for: .milliseconds(120))

            case let .screenshot(label):
                screenshotIndex += 1
                await screenshotVNC(
                    label, host: host, screenshotDir: screenshotDir,
                    index: screenshotIndex, stepIndex: stepIndex
                )

            case let .log(message):
                Log.info("[SA/VNC step \(stepIndex)] \(message)")

            case let .dualModifiedKey(mod1, mod2, key):
                Log.debug("[SA/VNC step \(stepIndex)] dualModifiedKey \(mod1)+\(mod2)+\(key)")
                let mod1Keysym = vncModifierKeysym(mod1)
                let mod2Keysym = vncModifierKeysym(mod2)
                let target = keysym(for: key)
                try client.sendKeyEvent(keysym: mod1Keysym, down: true)
                try client.sendKeyEvent(keysym: mod2Keysym, down: true)
                try client.sendKeyEvent(keysym: target, down: true)
                try client.sendKeyEvent(keysym: target, down: false)
                try client.sendKeyEvent(keysym: mod2Keysym, down: false)
                try client.sendKeyEvent(keysym: mod1Keysym, down: false)
                try await Task.sleep(for: .milliseconds(150))

            case let .hostShell(command, label, expectContains):
                try await SetupAssistantSequence.runHostShell(
                    stepIndex: stepIndex, command: command, label: label,
                    expectContains: expectContains, runner: "SA/VNC"
                )

            case let .dispatch(rules, maxIterations):
                Log.info("[SA/VNC step \(stepIndex)] dispatch over \(rules.count) rules")
                try await SetupAssistantSequence.runDispatchVNC(
                    rules: rules, host: host, client: client,
                    screenshotDir: screenshotDir, maxIterations: maxIterations
                )
            }
        }
    }

    private static func typeStringVNC(
        _ string: String, client: RFBClient, stepIndex: Int
    ) async throws {
        Log.debug("[SA/VNC step \(stepIndex)] type \"\(string)\"")
        for character in string {
            // `_VZVNCServer` strips the Shift modifier from shifted-ASCII
            // keysyms (`&` arrives as `7`, uppercase as lowercase), so
            // synthesize Shift explicitly around the unshifted base key.
            if let baseKeysym = shiftedAsciiBase(for: character) {
                try client.sendKeyEvent(keysym: RFBClient.KeySym.shiftLeft, down: true)
                try client.sendKeyEvent(keysym: baseKeysym, down: true)
                try client.sendKeyEvent(keysym: baseKeysym, down: false)
                try client.sendKeyEvent(keysym: RFBClient.KeySym.shiftLeft, down: false)
            } else if let ks = RFBClient.KeySym.character(character) {
                try client.tapKey(keysym: ks)
            } else {
                Log.info("VNC: skipping non-ASCII character \(character)")
                continue
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func verifyTextVNC(
        _ target: String, host: FirstBootHost, stepIndex: Int
    ) async throws {
        Log.info("[SA/VNC step \(stepIndex)] verifyText \"\(target)\"")
        let tempImage = FileManager.default.temporaryDirectory
            .appending(path: "vz-verify-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempImage) }
        try await MainActor.run {
            try Screenshot.captureContentView(host.view, to: tempImage)
        }
        let observations = try FramebufferOCR.recognize(
            imageURL: tempImage,
            framebufferSize: CGSize(width: 1280, height: 720)
        )
        if FramebufferOCR.find(target, in: observations) == nil {
            let seen = observations.prefix(20).map { $0.text }
            throw VMError(
                "verifyText failed: expected \"\(target)\" on the framebuffer. " +
                    "Saw: \(seen.joined(separator: " | "))"
            )
        }
        Log.info("[SA/VNC step \(stepIndex)] verifyText OK")
    }

    private static func clickByTextVNC(
        _ target: String, host: FirstBootHost, client: RFBClient, stepIndex: Int
    ) async throws {
        Log.info("[SA/VNC step \(stepIndex)] clickByText \"\(target)\"")
        let tempImage = FileManager.default.temporaryDirectory
            .appending(path: "vz-ocr-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tempImage) }
        try await MainActor.run {
            try Screenshot.captureContentView(host.view, to: tempImage)
        }
        let framebuffer = CGSize(width: 1280, height: 720)
        let observations = try FramebufferOCR.recognize(
            imageURL: tempImage, framebufferSize: framebuffer
        )
        guard let match = FramebufferOCR.find(
            target, in: observations, framebufferSize: framebuffer
        ) else {
            let nearby = observations.prefix(20).map { $0.text }
            throw VMError(
                "OCR could not find \"\(target)\" on the framebuffer. " +
                    "Saw: \(nearby.joined(separator: " | "))"
            )
        }
        Log.info(
            "[SA/VNC step \(stepIndex)] OCR match \"\(match.text)\" → " +
                "click (\(Int(match.center.x)), \(Int(match.center.y)))"
        )
        try await leftClickWithHold(
            client: client,
            x: UInt16(clamping: Int(match.center.x)),
            y: UInt16(clamping: Int(match.center.y))
        )
    }

    private static func screenshotVNC(
        _ label: String, host: FirstBootHost, screenshotDir: URL?,
        index: Int, stepIndex: Int
    ) async {
        guard let screenshotDir else {
            Log.debug("[SA/VNC step \(stepIndex)] screenshot \(label) (no dir; skipping)")
            return
        }
        let url = screenshotDir.appending(
            path: String(format: "%02d-%@.png", index, label)
        )
        do {
            try await MainActor.run {
                try Screenshot.captureWindow(host.window, to: url)
            }
            Log.info("[SA/VNC step \(stepIndex)] screenshot → \(url.lastPathComponent)")
        } catch {
            Log.info("[SA/VNC step \(stepIndex)] screenshot \(label) skipped (non-fatal): \(error)")
        }
    }

    /// Run a shell command on the host (not the guest). Combined
    /// stdout+stderr is logged; if `expectContains` is non-nil, throws
    /// when the output doesn't contain that substring. Used by the
    /// `driveXcodePreview` preset to issue SSH commands at the right
    /// moment between keystrokes.
    static func runHostShell(
        stepIndex: Int,
        command: String,
        label: String,
        expectContains: String?,
        runner: String
    ) async throws {
        Log.info("[\(runner) step \(stepIndex)] hostShell \"\(label)\"")
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-c", command]
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdoutData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let combined = stdout + stderr
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Log.info("[\(runner) step \(stepIndex)] \(label) → \(trimmed)")
        }
        if process.terminationStatus != 0 {
            throw VMError(
                "hostShell \"\(label)\" exited \(process.terminationStatus): \(trimmed)"
            )
        }
        if let needle = expectContains, !combined.contains(needle) {
            throw VMError(
                "hostShell \"\(label)\" output did not contain \"\(needle)\": \(trimmed)"
            )
        }
    }

    /// Send a left click with proper down/up timing. `RFBClient.leftClick`
    /// fires the pointer-move + button-down + button-up events
    /// back-to-back with no spacing — fast enough that macOS HID can
    /// treat them as "no actual press" for certain UI elements
    /// (menu-bar items especially, where a single fast click registers
    /// as movement-only and doesn't open the dropdown). This variant
    /// inserts realistic dwell times: settle after move, hold the
    /// button down for ~300ms before releasing — long enough that even
    /// recoveryOS's HID stack treats it as a deliberate click.
    private static func leftClickWithHold(
        client: RFBClient,
        x: UInt16,
        y: UInt16
    ) async throws {
        try client.sendPointerEvent(buttonMask: 0, x: x, y: y) // move
        try await Task.sleep(for: .milliseconds(150))
        try client.sendPointerEvent(buttonMask: 1, x: x, y: y) // down
        try await Task.sleep(for: .milliseconds(300))
        try client.sendPointerEvent(buttonMask: 0, x: x, y: y) // up
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Map a shifted-ASCII character to the unshifted base key it lives
    /// on (US ANSI layout). The runner sends Shift + base for these,
    /// since `_VZVNCServer` silently drops the Shift modifier when it's
    /// implicit in the keysym (e.g., sending 0x26 / `&` arrives in the
    /// guest as `7`).
    private static let shiftedAsciiBases: [Character: UInt32] = [
        "~": 0x60, "!": 0x31, "@": 0x32, "#": 0x33, "$": 0x34, "%": 0x35,
        "^": 0x36, "&": 0x37, "*": 0x38, "(": 0x39, ")": 0x30, "_": 0x2D,
        "+": 0x3D, "{": 0x5B, "}": 0x5D, "|": 0x5C, ":": 0x3B, "\"": 0x27,
        "<": 0x2C, ">": 0x2E, "?": 0x2F,
    ]

    private static func shiftedAsciiBase(for c: Character) -> UInt32? {
        if let base = shiftedAsciiBases[c] { return base }
        guard let scalar = c.unicodeScalars.first else { return nil }
        let v = scalar.value
        if v >= 0x41, v <= 0x5A { return v + 0x20 }
        return nil
    }

    private static func vncModifierKeysym(_ modifier: Modifier) -> UInt32 {
        switch modifier {
        case .shift: RFBClient.KeySym.shiftLeft
        case .command: RFBClient.KeySym.commandLeft
        case .option: RFBClient.KeySym.optionLeft
        case .control: RFBClient.KeySym.controlLeft
        }
    }

    /// Map `KeyboardScripter.Key` → X11 keysym for the VNC path.
    private static let plainKeysyms: [KeyboardScripter.Key: UInt32] = [
        .tab: RFBClient.KeySym.tab,
        .returnKey: RFBClient.KeySym.returnKey,
        .space: RFBClient.KeySym.space,
        .escape: RFBClient.KeySym.escape,
        .delete: RFBClient.KeySym.backspace,
        .leftArrow: RFBClient.KeySym.leftArrow,
        .rightArrow: RFBClient.KeySym.rightArrow,
        .upArrow: RFBClient.KeySym.upArrow,
        .downArrow: RFBClient.KeySym.downArrow,
        .f1: RFBClient.KeySym.f1, .f2: RFBClient.KeySym.f2, .f3: RFBClient.KeySym.f3,
        .f4: RFBClient.KeySym.f4, .f5: RFBClient.KeySym.f5, .f6: RFBClient.KeySym.f6,
        .f7: RFBClient.KeySym.f7, .f8: RFBClient.KeySym.f8, .f9: RFBClient.KeySym.f9,
        .f10: RFBClient.KeySym.f10, .f11: RFBClient.KeySym.f11, .f12: RFBClient.KeySym.f12,
    ]

    private static func keysym(for key: KeyboardScripter.Key) -> UInt32 {
        plainKeysyms[key] ?? 0
    }
}

/// Capture utilities for the host window.
///
/// - `captureWindow` shells out to `/usr/sbin/screencapture -l
///   <windowID>` and includes the window chrome (title bar, traffic
///   lights). Good for human-readable debugging screenshots.
/// - `captureContentView` renders only the view's contents via AppKit
///   `cacheDisplay(in:to:)`. The output's aspect ratio matches the
///   framebuffer exactly — used by the OCR path so coordinate
///   translation isn't thrown off by the title bar offset.
@MainActor
public enum Screenshot {
    public static func captureWindow(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/screencapture")
        process.arguments = [
            "-x", "-t", "png",
            "-l", "\(CGWindowID(window.windowNumber))",
            url.path,
        ]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
            let errStr = String(data: errData, encoding: .utf8) ?? ""
            throw VMError(
                "screencapture exited \(process.terminationStatus): \(errStr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw VMError("screencapture exited 0 but produced no file at \(url.path)")
        }
    }

    /// Render `view`'s current content into a PNG at `url`. Output
    /// dimensions are the view's bounds in points × backing scale —
    /// no title bar, no window chrome.
    public static func captureContentView(_ view: NSView, to url: URL) throws {
        let bounds = view.bounds
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw VMError("could not allocate bitmap rep for \(view)")
        }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw VMError("could not encode PNG from view bitmap")
        }
        do {
            try png.write(to: url)
        } catch {
            throw VMError("could not write content-view PNG to \(url.path)", underlying: error)
        }
    }
}
