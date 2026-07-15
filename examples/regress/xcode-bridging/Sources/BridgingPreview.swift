import SwiftUI

struct BridgingView: View {
    var body: some View {
        Text(BridgedGreeting.greeting())
            .padding()
    }
}

#Preview("Bridging header") {
    BridgingView()
}
