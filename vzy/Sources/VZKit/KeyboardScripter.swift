import AppKit
import Foundation

/// Synthesizes `NSEvent.keyEvent`s and posts them via `NSApp.postEvent`
/// so a `VZVirtualMachineView` hosted in an off-screen window receives
/// them as the guest's keyboard input.
///
/// Apple DTS (forum 769556) confirmed there is no public
/// `VZUSBKeyboard.sendKey`. The only public-API path for programmatic
/// keystrokes is to synthesize an `NSEvent` and route it through
/// AppKit's normal dispatch — `VZVirtualMachineView` overrides
/// `keyDown`/`keyUp` and forwards to the guest's USB keyboard.
///
/// **Modifiers note.** Sending modifier-required characters (uppercase,
/// `Cmd+…`, etc.) requires sandwiching `keyDown`/`keyUp` between
/// `flagsChanged` events with undocumented bits `0x108` (press) /
/// `0x100` (release). That isn't implemented yet — keep usernames /
/// passwords lowercase for now. (See forum 766014.)
@MainActor
public struct KeyboardScripter {
    public let window: NSWindow
    public let view: NSView

    public init(window: NSWindow, view: NSView) {
        self.window = window
        self.view = view
    }

    /// Send a single keystroke (keyDown + keyUp). Returns after queuing;
    /// callers should `await Task.sleep` for the dispatch loop to pick up
    /// the event and the guest to react. 50 ms between keys is a safe
    /// default for Setup Assistant-grade UIs.
    public func send(_ key: Key) {
        guard let down = makeEvent(.keyDown, key: key),
              let up = makeEvent(.keyUp, key: key)
        else {
            Log.info("could not synthesize NSEvent for \(key)")
            return
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    /// Type a literal string. ASCII-only; uppercase/symbols requiring
    /// modifiers are filtered out (and logged) until the
    /// flagsChanged-modifier path lands.
    public func type(_ string: String) {
        for character in string {
            guard let key = Key.character(character) else {
                Log
                    .info(
                        "KeyboardScripter: skipping unsupported character \(character.unicodeScalars.first?.value.description ?? "?")"
                    )
                continue
            }
            send(key)
        }
    }

    /// Send `key`, then wait `interval` seconds. Convenience for
    /// wait-and-tab scripts where each keystroke triggers a UI
    /// transition that takes time to render.
    public func sendAndWait(_ key: Key, _ interval: TimeInterval) async {
        send(key)
        try? await Task.sleep(for: .seconds(interval))
    }

    /// Send a left mouse click at `point` in WINDOW coordinates
    /// (bottom-left origin). VZVirtualMachineView scales window coords
    /// to the guest's framebuffer coords internally.
    ///
    /// Setup Assistant on macOS 26.3+ requires mouse clicks for some
    /// transitions where keyboard input alone leaves the Continue
    /// button disabled (e.g., the Country/Region picker).
    public func click(at point: NSPoint) {
        let down = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )
        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )
        guard let down, let up else {
            Log.info("could not synthesize NSEvent for mouse click at \(point)")
            return
        }
        NSApp.postEvent(down, atStart: false)
        NSApp.postEvent(up, atStart: false)
    }

    private func makeEvent(_ type: NSEvent.EventType, key: Key) -> NSEvent? {
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: key.characters,
            charactersIgnoringModifiers: key.characters,
            isARepeat: false,
            keyCode: key.code
        )
    }
}

public extension KeyboardScripter {
    /// US-ANSI keyboard mapping. Covers the keys Setup Assistant
    /// navigation needs (Tab/Return/Space/Esc/arrows) and the unshifted
    /// printable ASCII subset for username/password typing.
    enum Key: Hashable, Sendable {
        case tab
        case returnKey
        case space
        case escape
        case delete
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        case character(unicodeScalar: UInt32, code: UInt16)

        public static func character(_ c: Character) -> Key? {
            guard c.isASCII, let scalar = c.unicodeScalars.first else { return nil }
            guard let code = keyCodeForUnshiftedASCII(c) else { return nil }
            return .character(unicodeScalar: scalar.value, code: code)
        }

        public var code: UInt16 {
            switch self {
            case .tab: 48
            case .returnKey: 36
            case .space: 49
            case .escape: 53
            case .delete: 51
            case .leftArrow: 123
            case .rightArrow: 124
            case .downArrow: 125
            case .upArrow: 126
            // macOS virtual keycodes for F-keys (Carbon HIToolbox).
            case .f1: 122
            case .f2: 120
            case .f3: 99
            case .f4: 118
            case .f5: 96
            case .f6: 97
            case .f7: 98
            case .f8: 100
            case .f9: 101
            case .f10: 109
            case .f11: 103
            case .f12: 111
            case let .character(_, code): code
            }
        }

        public var characters: String {
            switch self {
            case .tab: return "\t"
            case .returnKey: return "\r"
            case .space: return " "
            case .escape: return "\u{1B}"
            case .delete: return "\u{08}"
            case .leftArrow: return "\u{F702}"
            case .rightArrow: return "\u{F703}"
            case .upArrow: return "\u{F700}"
            case .downArrow: return "\u{F701}"
            // NSEvent unicode for F-keys.
            case .f1: return "\u{F704}"
            case .f2: return "\u{F705}"
            case .f3: return "\u{F706}"
            case .f4: return "\u{F707}"
            case .f5: return "\u{F708}"
            case .f6: return "\u{F709}"
            case .f7: return "\u{F70A}"
            case .f8: return "\u{F70B}"
            case .f9: return "\u{F70C}"
            case .f10: return "\u{F70D}"
            case .f11: return "\u{F70E}"
            case .f12: return "\u{F70F}"
            case let .character(value, _):
                guard let scalar = Unicode.Scalar(value) else { return "" }
                return String(Character(scalar))
            }
        }

        /// US ANSI virtual keycodes for unshifted printable ASCII. Absent
        /// for characters that need shift (uppercase + most symbols) —
        /// those need the flagsChanged modifier path (not yet implemented).
        private static let unshiftedASCIIKeyCodes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
        ]

        private static func keyCodeForUnshiftedASCII(_ c: Character) -> UInt16? {
            unshiftedASCIIKeyCodes[c]
        }
    }
}
