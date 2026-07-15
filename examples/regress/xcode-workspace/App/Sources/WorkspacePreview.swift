import SharedKit
import SwiftUI

struct WorkspaceFixtureView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(WorkspaceMessage.value)
            #if PREVIEW_WORKSPACE
                Text("custom workspace configuration")
            #else
                Text("wrong Xcode configuration")
                    .foregroundStyle(.red)
            #endif
        }
        .padding()
    }
}

#Preview("Workspace target ownership") {
    WorkspaceFixtureView()
}
