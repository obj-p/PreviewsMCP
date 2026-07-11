import SwiftUI
@testable import Stable

struct SplitPreview: View {
    var body: some View {
        ZStack {
            Color(red: 0, green: 0, blue: 1)
            StableView(label: "v2")
                .padding(stableInset())
        }
    }
}

@_cdecl("preview_render_pixel")
public func preview_render_pixel() -> UInt32 {
    MainActor.assumeIsolated {
        let renderer = ImageRenderer(content: SplitPreview().frame(width: 8, height: 8))
        guard let cg = renderer.cgImage else { return 0xDEAD_0000 }
        guard let provider = cg.dataProvider, let data = provider.data,
              let ptr = CFDataGetBytePtr(data) else { return 0xBEEF_0000 }
        let off = 0
        return UInt32(ptr[off]) << 16 | UInt32(ptr[off + 1]) << 8 | UInt32(ptr[off + 2])
    }
}
