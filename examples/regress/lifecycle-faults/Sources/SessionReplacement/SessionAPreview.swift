import SwiftUI

struct SessionAView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Session A")
                .font(.title)
            Button("A count: \(count)") {
                count += 1
            }
            .accessibilityIdentifier("session-a-counter")
        }
        .padding()
    }
}

#Preview("Session A") {
    SessionAView()
}
