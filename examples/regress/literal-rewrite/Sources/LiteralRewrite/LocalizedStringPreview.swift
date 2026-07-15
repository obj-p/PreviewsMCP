import Foundation
import SwiftUI

struct LocalizedStringFixtureView: View {
    var body: some View {
        Text(String(localized: "literal.fixture.title", bundle: .main))
            .padding()
    }
}

#Preview("Contextually typed localized key") {
    LocalizedStringFixtureView()
}
