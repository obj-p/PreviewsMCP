import DynamicBadge
import Foundation
import SwiftUI

struct DynamicBinaryView: View {
    private var frameworkResource: String {
        guard let marker = NSClassFromString("DynamicBadgeMarker")
        else { return "framework class not registered" }
        let bundle = Bundle(for: marker)
        guard bundle.bundleURL.lastPathComponent == "DynamicBadge.framework"
        else { return "framework bundle unresolved (\(bundle.bundleURL.lastPathComponent))" }
        guard let url = bundle.url(forResource: "fixture-payload", withExtension: "json")
        else { return "framework resource missing" }
        guard let value = try? String(contentsOf: url, encoding: .utf8)
        else { return "framework resource unreadable" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(String(cString: dynamic_badge_message()))
            Text(frameworkResource)
                .font(.caption)
        }
        .padding()
    }
}

#Preview("Dynamic XCFramework only") {
    DynamicBinaryView()
}
