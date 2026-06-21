import SwiftUI
import UIKit

@_cdecl("ios_render_probe_value")
public func ios_render_probe_value() -> Int32 {
    MainActor.assumeIsolated {
        let content = Color(red: 1, green: 0, blue: 0).frame(width: 8, height: 8)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else {
            return Int32(-1)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            return Int32(-2)
        }
        let w = CGFloat(cgImage.width)
        let h = CGFloat(cgImage.height)
        ctx.draw(cgImage, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        let r = Int32(pixel[0])
        let g = Int32(pixel[1])
        let b = Int32(pixel[2])
        return (r << 16) | (g << 8) | b
    }
}
