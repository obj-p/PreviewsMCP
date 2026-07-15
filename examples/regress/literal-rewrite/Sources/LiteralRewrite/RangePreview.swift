import SwiftUI

struct RangeFixtureView: View {
    var body: some View {
        VStack {
            ForEach(0 ..< 12, id: \.self) { index in
                Text("Range row \(index)")
            }
        }
        .padding()
    }
}

#Preview("Half-open range") {
    RangeFixtureView()
}
