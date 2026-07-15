import DynamicBadge
import Foundation
import SwiftUI

struct DynamicBinaryView: View {
    private var frameworkResource: String {
        guard let bundle = Bundle.allFrameworks.first(where: {
            $0.bundleURL.lastPathComponent == "DynamicBadge.framework"
        }),
            let url = bundle.url(forResource: "fixture-payload", withExtension: "json"),
            let value = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "framework resource missing"
        }
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
