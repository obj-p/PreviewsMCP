import SwiftUI

struct RuntimeFrameworkView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Preview file imports only SwiftUI")
            Text("Other target files emit system-framework autolinks")
                .font(.caption)
        }
        .multilineTextAlignment(.center)
        .padding()
    }
}

#Preview("Transitive system frameworks") {
    RuntimeFrameworkView()
}
