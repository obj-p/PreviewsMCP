import Foundation
import SwiftUI

struct RuntimeResourceView: View {
    private static let titleKey: String.LocalizationValue = "resource.title"

    private let locale: Locale
    private let payload: String
    private let textResourceLoaded: Bool

    init(locale: Locale = .current) {
        self.locale = locale

        if let url = Bundle.module.url(forResource: "payload", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        {
            payload = object["message"] ?? "Missing JSON value"
        } else {
            payload = "Missing payload.json"
        }

        textResourceLoaded = Bundle.module.url(
            forResource: "fixture-note",
            withExtension: "txt"
        ) != nil
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(String(localized: Self.titleKey, bundle: .module, locale: locale))
                .font(.headline)
            Text(payload)
            Label(
                textResourceLoaded ? "Text resource loaded" : "Text resource missing",
                systemImage: textResourceLoaded ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
        }
        .padding()
    }
}

#Preview("English resources") {
    RuntimeResourceView(locale: Locale(identifier: "en"))
}

#Preview("Spanish resources") {
    RuntimeResourceView(locale: Locale(identifier: "es"))
}
