import Foundation
import SwiftUI

struct HotReloadFixtureView: View {
    private var resourceValue: String {
        guard let url = Bundle.module.url(forResource: "reload-value", withExtension: "txt"),
              let value = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "resource missing"
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(MutationModel.value)
            Text(RenameCandidate.value)
            Text(resourceValue)
        }
        .padding()
    }
}

#Preview("Watcher mutations") {
    HotReloadFixtureView()
}
