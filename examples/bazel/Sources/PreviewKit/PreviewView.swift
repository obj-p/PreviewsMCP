import SwiftUI

public struct PreviewView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Text("preview kit framework")
            Image(systemName: "star.fill")
        }
        .padding()
    }
}

#Preview {
    PreviewView()
}
