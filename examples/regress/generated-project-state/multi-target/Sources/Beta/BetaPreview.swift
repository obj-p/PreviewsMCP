import SwiftUI

struct BetaView: View {
    let model = BetaModel()

    var body: some View {
        Text(model.title)
            .padding()
    }
}

#Preview("Second target") {
    BetaView()
}
