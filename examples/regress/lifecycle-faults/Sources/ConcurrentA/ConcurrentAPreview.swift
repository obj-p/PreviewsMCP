import SwiftUI

struct ConcurrentAView: View {
    var body: some View {
        Text("concurrent session A")
            .padding()
    }
}

#Preview("Concurrent A") {
    ConcurrentAView()
}
