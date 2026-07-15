import SwiftUI

struct LargeTier2View: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("Large Tier 2 target")
                .font(.headline)
            Text("Generated files: \(GeneratedCatalog.fileCount)")
                .monospacedDigit()
        }
        .padding()
    }
}

#Preview("Large compile") {
    LargeTier2View()
}
