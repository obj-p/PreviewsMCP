import SwiftUI

struct OuterBoundaryView: View {
    var body: some View {
        Text("Outer Package.swift must not win")
            .padding()
    }
}

#Preview("Xcode inside SwiftPM") {
    OuterBoundaryView()
}
