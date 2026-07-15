import SwiftUI

struct SessionBView: View {
    @State private var count = 0

    var body: some View {
        VStack(spacing: 12) {
            Text("Session B")
                .font(.title)
            Button("B count: \(count)") {
                count += 1
            }
            .accessibilityIdentifier("session-b-counter")
        }
        .padding()
    }
}

#Preview("Session B") {
    SessionBView()
}
