import SwiftUI

struct ProbeView: View {
    let value: Int32
    var body: some View {
        Text(String(value))
    }
}

@_cdecl("swiftui_probe_value")
public func swiftui_probe_value() -> Int32 {
    let view = ProbeView(value: 7)
    _ = view.body
    return view.value
}
