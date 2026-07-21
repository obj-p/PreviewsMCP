import Foundation
import SwiftUI

struct RuntimeResourceView: View {
    private let title: String
    private let payload: String
    private let textResourceLoaded: Bool

    init(locale: Locale = .current) {
        title = Self.localizedTitle(
            localeIdentifier: locale.language.languageCode?.identifier ?? locale.identifier
        )

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

    private static func localizedTitle(localeIdentifier: String) -> String {
        guard
            let path = Bundle.module.path(forResource: localeIdentifier, ofType: "lproj"),
            let bundle = Bundle(path: path)
        else { return "\(localeIdentifier).lproj missing" }
        return bundle.localizedString(
            forKey: "resource.title", value: "resource.title unresolved", table: nil
        )
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
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
