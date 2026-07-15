import FixtureC
import Foundation
import SwiftUI

protocol FixtureMessageProviding {
    var message: String { get }
}

private struct FixtureMessage: FixtureMessageProviding {
    let message: String
}

struct SettingsFixtureView: View {
    private static let titleKey: String.LocalizationValue = "fixture.title"

    private let provider: any FixtureMessageProviding

    init() {
        let resourceName: String = if let url = Bundle.module.url(forResource: "settings", withExtension: "json"),
                                      let data = try? Data(contentsOf: url),
                                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        {
            object["name"] ?? "missing resource value"
        } else {
            "missing settings.json"
        }

        provider = FixtureMessage(message: resourceName)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(String(localized: Self.titleKey, bundle: .module))
                .font(.headline)
            Text(provider.message)
            Text(GeneratedFixtureStamp.value)
            Text("C module value: \(fixture_c_magic())")
            #if SETTINGS_FIXTURE
                Text("Conditional Swift setting present")
            #else
                Text("Conditional Swift setting missing")
                    .foregroundStyle(.red)
            #endif
        }
        .padding()
    }
}

#Preview("SwiftPM settings") {
    SettingsFixtureView()
}
