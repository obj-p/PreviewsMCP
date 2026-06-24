import SwiftUI

struct HostingProbeView: View {
    var body: some View {
        Text("hi").padding()
    }
}

@_cdecl("hosting_probe_value")
public func hosting_probe_value() -> Int32 {
    let hosting = NSHostingView(rootView: HostingProbeView())
    hosting.layoutSubtreeIfNeeded()
    return hosting.fittingSize.width > 0 ? 1 : 0
}
