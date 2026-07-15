import LocalBadge
import SwiftUI

public struct BzlmodFixtureView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            Text(LocalBadge.message)
            Text(GeneratedBuildStamp.value)
        }
        .padding()
    }
}

#Preview("Bzlmod external and generated source") {
    BzlmodFixtureView()
}
