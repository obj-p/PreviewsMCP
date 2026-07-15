import SwiftUI

struct ConfigCacheFixtureView: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(colorScheme == .dark ? "dark" : "light")
            .font(.title)
            .padding()
    }
}

#Preview("Config cache") {
    ConfigCacheFixtureView()
}
