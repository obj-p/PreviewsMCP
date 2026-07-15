import SwiftUI

public struct HybridMarkerView: View {
    public init() {}

    public var body: some View {
        Text("Same-directory marker precedence")
            .padding()
    }
}

#Preview("SwiftPM or Bazel") {
    HybridMarkerView()
}
