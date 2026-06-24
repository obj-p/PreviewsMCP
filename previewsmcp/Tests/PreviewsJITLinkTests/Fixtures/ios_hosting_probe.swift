import SwiftUI
import UIKit

struct IOSHostingProbeView: View {
    var body: some View {
        Text("hi").padding()
    }
}

@_cdecl("ios_hosting_probe_value")
public func ios_hosting_probe_value() -> Int32 {
    MainActor.assumeIsolated {
        let host = UIHostingController(rootView: IOSHostingProbeView())
        host.loadViewIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 1000, height: 1000))
        return size.width > 0 ? 1 : 0
    }
}
