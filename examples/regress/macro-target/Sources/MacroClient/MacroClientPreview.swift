import FixtureMacros
import SwiftUI

struct MacroClientView: View {
    var body: some View {
        Text(#fixtureStamp())
            .padding()
    }
}

#Preview("Custom macro") {
    MacroClientView()
}
