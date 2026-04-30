import Foundation
import Testing

@testable import PreviewsCLI

/// Deterministic test environment — avoids touching the real process env.
struct MockTerminalEnvironment: TerminalEnvironment {
    var term: String?
    var termProgram: String?
    var lcTerminal: String?
    var kittyWindowID: String?
    var tmux: String?
    var previewsmcpInline: String?
}

/// Test double for `tmux show-options` — avoids spawning a real tmux process
/// so capability tests run deterministically in any environment (CI, local,
/// in/out of tmux).
struct StubTmuxProbe: TmuxProbe {
    let state: TmuxPassthroughState
    func allowPassthrough() -> TmuxPassthroughState { state }
}

@Suite("ITerm2Encoder")
struct ITerm2EncoderTests {
    @Test("encodes a fixed 4-byte payload to the documented OSC 1337 framing")
    func goldenBytes() {
        let input = Data([0x00, 0x01, 0x02, 0x03])
        let output = ITerm2Encoder.encode(imageData: input)
        let expected = "\u{1B}]1337;File=inline=1;size=4:AAECAw==\u{07}"
        #expect(String(data: output, encoding: .utf8) == expected)
    }

    @Test("size header matches raw byte length, not base64 length")
    func sizeIsRawByteCount() {
        // 5 bytes encode to 8 base64 chars — size must report 5.
        let input = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42])
        let output = ITerm2Encoder.encode(imageData: input)
        let s = String(data: output, encoding: .utf8) ?? ""
        #expect(s.contains(";size=5:"))
        #expect(!s.contains(";size=8:"))
    }
}

@Suite("TmuxPassthrough")
struct TmuxPassthroughTests {
    @Test("wraps with ESC P tmux ; … ESC \\")
    func framesWithDCS() {
        let inner = Data([0x41, 0x42])   // "AB", no ESC inside
        let wrapped = TmuxPassthrough.wrap(inner)
        let expected = Data([0x1B, 0x50])          // ESC P
            + Data("tmux;".utf8)
            + Data([0x41, 0x42])
            + Data([0x1B, 0x5C])                   // ESC \
        #expect(wrapped == expected)
    }

    @Test("doubles every inner ESC (0x1B → 0x1B 0x1B)")
    func doublesEscapes() {
        let inner = Data([0x1B, 0x41, 0x1B])
        let wrapped = TmuxPassthrough.wrap(inner)
        let expected = Data([0x1B, 0x50])
            + Data("tmux;".utf8)
            + Data([0x1B, 0x1B, 0x41, 0x1B, 0x1B])
            + Data([0x1B, 0x5C])
        #expect(wrapped == expected)
    }

    @Test("wrapping an iTerm2 payload produces a tmux-ready double-ESC prefix")
    func wrapIntegratesWithITerm2Encoder() {
        let image = Data([0x00, 0x01, 0x02, 0x03])
        let inner = ITerm2Encoder.encode(imageData: image)
        let wrapped = TmuxPassthrough.wrap(inner)
        // The only ESC in the iTerm2 payload is the leading one — it must
        // appear doubled in the wrapped output.
        let s = String(data: wrapped, encoding: .utf8) ?? ""
        #expect(s.hasPrefix("\u{1B}Ptmux;\u{1B}\u{1B}]1337;"))
        #expect(s.hasSuffix("\u{07}\u{1B}\\"))
    }
}

@Suite("TerminalCapabilityDetector")
struct TerminalCapabilityDetectorTests {
    @Test(
        "outer terminal classification",
        arguments: [
            (MockTerminalEnvironment(termProgram: "iTerm.app"), TerminalCapability.iTerm2),
            (MockTerminalEnvironment(termProgram: "WezTerm"), .iTerm2),
            (MockTerminalEnvironment(termProgram: "ghostty"), .iTerm2),
            (MockTerminalEnvironment(lcTerminal: "iTerm2"), .iTerm2),
            (MockTerminalEnvironment(term: "xterm-kitty"), .kittyOnly),
            (MockTerminalEnvironment(kittyWindowID: "1"), .kittyOnly),
            (MockTerminalEnvironment(term: "xterm-256color"), .unsupported),
            (MockTerminalEnvironment(), .unsupported),
        ] as [(MockTerminalEnvironment, TerminalCapability)]
    )
    func classifiesOuterTerminal(env: MockTerminalEnvironment, expected: TerminalCapability) {
        let decision = TerminalCapabilityDetector.detect(
            env: env, tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        #expect(decision.capability == expected)
        #expect(decision.needsTmuxWrap == false)
        #expect(decision.hint == nil)
    }

    @Test("tmux + supported outer + passthrough on → needsTmuxWrap")
    func tmuxOnWraps() {
        let env = MockTerminalEnvironment(termProgram: "iTerm.app", tmux: "/tmp/tmux-500/default,1234,0")
        let decision = TerminalCapabilityDetector.detect(env: env, tmuxProbe: StubTmuxProbe(state: .on))
        #expect(decision.capability == .iTerm2)
        #expect(decision.needsTmuxWrap == true)
        #expect(decision.hint == nil)
    }

    @Test("tmux + supported outer + passthrough off → unsupported + hint")
    func tmuxOffEmitsHint() {
        let env = MockTerminalEnvironment(termProgram: "iTerm.app", tmux: "/tmp/tmux-500/default,1234,0")
        let decision = TerminalCapabilityDetector.detect(env: env, tmuxProbe: StubTmuxProbe(state: .off))
        #expect(decision.capability == .unsupported)
        #expect(decision.needsTmuxWrap == false)
        #expect(decision.hint == TerminalCapabilityDetector.tmuxPassthroughOffHint)
    }

    @Test("tmux + supported outer + probe unknown → unsupported, no hint")
    func tmuxUnknownIsQuiet() {
        let env = MockTerminalEnvironment(termProgram: "iTerm.app", tmux: "/tmp/tmux-500/default,1234,0")
        let decision = TerminalCapabilityDetector.detect(env: env, tmuxProbe: StubTmuxProbe(state: .unknown))
        #expect(decision.capability == .unsupported)
        #expect(decision.hint == nil)
    }

    @Test("tmux + unsupported outer → do not probe, stay unsupported, no hint")
    func tmuxWithUnsupportedOuterSkipsProbe() {
        let env = MockTerminalEnvironment(term: "xterm-256color", tmux: "/tmp/tmux/default")
        // If this test accidentally calls through, the probe returns .on — which
        // *would* flip the decision if detection didn't short-circuit. Using a
        // probe that would cause the wrong answer is the trap we're guarding.
        let decision = TerminalCapabilityDetector.detect(env: env, tmuxProbe: StubTmuxProbe(state: .on))
        #expect(decision.capability == .unsupported)
        #expect(decision.needsTmuxWrap == false)
        #expect(decision.hint == nil)
    }
}

@Suite("TerminalImages.renderInline")
struct TerminalImagesRenderInlineTests {
    private let pixel = Data([0x01, 0x02, 0x03])

    @Test("--json always skips")
    func jsonSkips() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: true,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        #expect(d == .skip(hint: nil))
    }

    @Test("--inline never skips, even on TTY + supported terminal")
    func neverSkips() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .never, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        #expect(d == .skip(hint: nil))
    }

    @Test("auto + non-TTY skips (piped output)")
    func autoPipedSkips() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: false,
            env: MockTerminalEnvironment(termProgram: "iTerm.app"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        #expect(d == .skip(hint: nil))
    }

    @Test("auto + TTY + iTerm2 emits unwrapped OSC 1337")
    func autoTTYSupported() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        guard case .emit(let bytes, _) = d else { Issue.record("expected .emit"); return }
        let s = String(data: bytes, encoding: .utf8) ?? ""
        #expect(s.hasPrefix("\u{1B}]1337;"))
        #expect(!s.hasPrefix("\u{1B}Ptmux;"))
    }

    @Test("auto + TTY + tmux + passthrough on emits wrapped bytes")
    func autoTmuxOnWraps() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app", tmux: "/tmp/tmux/default"),
            tmuxProbe: StubTmuxProbe(state: .on)
        )
        guard case .emit(let bytes, _) = d else { Issue.record("expected .emit"); return }
        let s = String(data: bytes, encoding: .utf8) ?? ""
        #expect(s.hasPrefix("\u{1B}Ptmux;"))
        #expect(s.hasSuffix("\u{1B}\\"))
    }

    @Test("auto + TTY + tmux + passthrough off skips with hint")
    func autoTmuxOffSkipsWithHint() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app", tmux: "/tmp/tmux/default"),
            tmuxProbe: StubTmuxProbe(state: .off)
        )
        #expect(d == .skip(hint: TerminalCapabilityDetector.tmuxPassthroughOffHint))
    }

    @Test("always overrides unsupported terminal and emits with stderr hint")
    func alwaysOverridesUnsupported() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .always, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(term: "xterm-256color"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        guard case .emit(let bytes, let hint) = d else { Issue.record("expected .emit"); return }
        #expect(!bytes.isEmpty)
        #expect(hint == TerminalCapabilityDetector.forcedOnUnsupportedHint)
    }

    @Test("always overrides non-TTY stdout and emits")
    func alwaysOverridesPiped() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .always, jsonOutput: false,
            stdoutIsTTY: false,
            env: MockTerminalEnvironment(termProgram: "iTerm.app"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        guard case .emit = d else { Issue.record("expected .emit"); return }
    }

    @Test("PREVIEWSMCP_INLINE=0 + mode=auto → skip")
    func envVarNeverOverridesAuto() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app", previewsmcpInline: "0"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        #expect(d == .skip(hint: nil))
    }

    @Test("PREVIEWSMCP_INLINE=1 + mode=auto + non-TTY → emit (env forced always)")
    func envVarAlwaysBeatsNonTTY() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: false,
            env: MockTerminalEnvironment(termProgram: "iTerm.app", previewsmcpInline: "1"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        guard case .emit = d else { Issue.record("expected .emit"); return }
    }

    @Test(
        "PREVIEWSMCP_INLINE string variants resolved correctly under mode=auto",
        arguments: [
            ("0", false), ("false", false), ("never", false),
            ("1", true), ("true", true), ("always", true),
            ("auto", true), ("", true), ("garbage", true),
        ] as [(String, Bool)]
    )
    func envVarVariants(raw: String, shouldEmit: Bool) {
        let env = MockTerminalEnvironment(
            termProgram: "iTerm.app",
            previewsmcpInline: raw
        )
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .auto, jsonOutput: false,
            stdoutIsTTY: true,
            env: env,
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        switch d {
        case .emit: #expect(shouldEmit, "expected skip for PREVIEWSMCP_INLINE=\(raw)")
        case .skip: #expect(!shouldEmit, "expected emit for PREVIEWSMCP_INLINE=\(raw)")
        }
    }

    @Test("explicit --inline never wins over PREVIEWSMCP_INLINE=1")
    func flagBeatsEnv() {
        let d = TerminalImages.renderInline(
            imageData: pixel, mode: .never, jsonOutput: false,
            stdoutIsTTY: true,
            env: MockTerminalEnvironment(termProgram: "iTerm.app", previewsmcpInline: "1"),
            tmuxProbe: StubTmuxProbe(state: .unknown)
        )
        #expect(d == .skip(hint: nil))
    }
}
