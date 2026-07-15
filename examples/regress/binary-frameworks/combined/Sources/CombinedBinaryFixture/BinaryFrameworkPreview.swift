import DynamicBadge
import StaticBadge
import SwiftUI

struct BinaryFrameworkView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text(String(cString: static_badge_message()))
            Text(String(cString: dynamic_badge_message()))
        }
        .padding()
    }
}

#Preview("Static and dynamic XCFrameworks") {
    BinaryFrameworkView()
}
