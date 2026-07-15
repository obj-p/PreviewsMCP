import CoreData
import Foundation
import SwiftUI

private final class ResourceBundleToken {}

struct XcodeResourceView: View {
    private static let titleKey: String.LocalizationValue = "resource.title"

    private let bundle = Bundle(for: ResourceBundleToken.self)

    private var plistLoaded: Bool {
        bundle.url(forResource: "FixtureInfo", withExtension: "plist") != nil
    }

    private var modelLoaded: Bool {
        guard let url = bundle.url(forResource: "FixtureModel", withExtension: "momd") else {
            return false
        }
        return NSManagedObjectModel(contentsOf: url) != nil
    }

    var body: some View {
        VStack(spacing: 10) {
            Text(String(localized: Self.titleKey, bundle: bundle))
                .font(.headline)
            Label(
                plistLoaded ? "Plist loaded" : "Plist missing",
                systemImage: plistLoaded ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            Label(
                modelLoaded ? "Core Data model loaded" : "Core Data model missing",
                systemImage: modelLoaded ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.fixtureAccent)
                .frame(width: 120, height: 32)
                .accessibilityLabel("Generated asset symbol")
        }
        .padding()
    }
}

#Preview("Xcode resources") {
    XcodeResourceView()
}
