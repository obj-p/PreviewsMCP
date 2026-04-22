import Foundation

/// Emits the iTerm2 inline-image escape:
///
///     ESC ] 1337 ; File = inline=1 ; size=N : <base64> BEL
///
/// The payload's width/height are left to the terminal (`width=auto;height=auto`
/// is implicit when omitted). `size=N` is the raw-byte length (not base64 size);
/// iTerm2's docs recommend including it so the terminal can preallocate.
enum ITerm2Encoder {
    static func encode(imageData: Data) -> Data {
        let base64 = imageData.base64EncodedString()
        let header = "\u{1B}]1337;File=inline=1;size=\(imageData.count):"
        var out = Data()
        out.append(Data(header.utf8))
        out.append(Data(base64.utf8))
        out.append(0x07)
        return out
    }
}
