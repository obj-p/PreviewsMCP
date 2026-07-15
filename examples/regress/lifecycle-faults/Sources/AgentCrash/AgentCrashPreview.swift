import SwiftUI

struct AgentCrashView: View {
    var body: some View {
        Button("Crash preview agent") {
            fatalError("Intentional regression-fixture crash")
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("crash-preview-agent")
        .padding()
    }
}

#Preview("Crash on activation") {
    AgentCrashView()
}
