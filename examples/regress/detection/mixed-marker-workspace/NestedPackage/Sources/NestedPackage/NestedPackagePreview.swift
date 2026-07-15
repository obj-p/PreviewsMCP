import SwiftUI

public struct NestedPackageView: View {
    public init() {}

    public var body: some View {
        Text("Nearest marker: SwiftPM")
            .padding()
    }
}

#Preview("Nested SwiftPM") {
    NestedPackageView()
}
