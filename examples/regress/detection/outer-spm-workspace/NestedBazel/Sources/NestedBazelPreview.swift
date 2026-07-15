import SwiftUI

public struct NestedBazelView: View {
    public init() {}

    public var body: some View {
        Text("Outer Package.swift must not win")
            .padding()
    }
}

#Preview("Bazel inside SwiftPM") {
    NestedBazelView()
}
