import SwiftUI

@_cdecl("render_probe_value")
public func render_probe_value() -> Int32 {
    MainActor.assumeIsolated {
        let content = Color(red: 1, green: 0, blue: 0).frame(width: 8, height: 8)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else {
            return Int32(-1)
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard
            let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB)
        else {
            return Int32(-2)
        }
        let r = Int32((color.redComponent * 255).rounded())
        let g = Int32((color.greenComponent * 255).rounded())
        let b = Int32((color.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
