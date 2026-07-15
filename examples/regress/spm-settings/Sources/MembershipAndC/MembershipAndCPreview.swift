import FixtureC
import SwiftUI

struct MembershipAndCView: View {
    var body: some View {
        Text("C module value: \(fixture_c_magic())")
            .padding()
    }
}

#Preview("Membership and C module only") {
    MembershipAndCView()
}
