import SwiftUI

struct ConditionalFixtureView: View {
    let value: String

    var body: some View {
        Text(value)
            .padding()
    }
}

#if DEBUG
    #Preview("Debug conditional") {
        ConditionalFixtureView(value: "debug preview")
    }
#endif

#if os(iOS)
    #Preview("iOS conditional") {
        ConditionalFixtureView(value: "iOS preview")
    }
#endif
