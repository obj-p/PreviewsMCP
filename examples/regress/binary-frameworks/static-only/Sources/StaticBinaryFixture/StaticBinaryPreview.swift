import StaticBadge
import SwiftUI

struct StaticBinaryView: View {
    var body: some View {
        Text(String(cString: static_badge_message()))
            .padding()
    }
}

#Preview("Static XCFramework only") {
    StaticBinaryView()
}
