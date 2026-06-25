import Foundation

/// Namespace for `Key`, the keyboard mapping the VNC setup sequence
/// translates into X11 keysyms.
public enum KeyboardScripter {}

public extension KeyboardScripter {
    /// The keys Setup Assistant navigation needs (Tab/Return/Space/Esc/
    /// arrows/function keys). Printable characters are typed directly as
    /// keysyms by the VNC runner, so they aren't enumerated here.
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
    }
}
