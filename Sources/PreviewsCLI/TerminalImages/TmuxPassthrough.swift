import Foundation

/// Wraps an escape sequence so that tmux with `allow-passthrough on`
/// forwards it to the outer terminal.
///
/// Format: `ESC P tmux ; <inner-with-ESC-doubled> ESC \`
/// Every `0x1B` inside the inner payload is duplicated; tmux strips the
/// duplicate on the way out.
enum TmuxPassthrough {
    static func wrap(_ inner: Data) -> Data {
        var out = Data()
        out.append(contentsOf: [0x1B, 0x50])       // ESC P
        out.append(contentsOf: Array("tmux;".utf8))
        for byte in inner {
            if byte == 0x1B {
                out.append(0x1B)
                out.append(0x1B)
            } else {
                out.append(byte)
            }
        }
        out.append(contentsOf: [0x1B, 0x5C])       // ESC \
        return out
    }
}
