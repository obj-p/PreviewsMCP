import PreviewsSetupKit
import SwiftUI

// MARK: - Theme

/// A simple design system theme that could represent a company's brand.
/// In a real app, this would live in a shared design system module.
struct AppTheme: Sendable {
    let accentColor: Color
    let cardBackground: Color
    let headerFont: Font

    static let standard = AppTheme(
        accentColor: .blue,
        cardBackground: Color(.sRGB, white: 1.0),
        headerFont: .title2.bold()
    )

    static let brand = AppTheme(
        accentColor: Color(red: 0.4, green: 0.2, blue: 0.8),
        cardBackground: Color(red: 0.95, green: 0.93, blue: 1.0),
        headerFont: .title2.weight(.heavy)
    )
}

private struct AppThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme.standard
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

// MARK: - PreviewSetup conformance

/// Setup target for ToDo app previews.
///
/// This replaces what would otherwise be a separate "dev app" or "micro app"
/// target that teams maintain for isolated feature testing.
///
/// `setUp()` runs once when the host app launches — before any preview dylib
/// is loaded. Side effects persist across hot-reload cycles.
///
/// `wrap(_:)` runs on every preview render. Trait modifiers from
/// `preview_configure` are applied outside this wrapper, so explicit
/// overrides always take precedence.
public struct ToDoPreviewSetup: PreviewSetup {

    public static func setUp() async throws {
        // In a real app, this is where you'd initialize SDKs:
        //
        //   FirebaseApp.configure()
        //   FontManager.registerCustomFonts()
        //   AnalyticsService.shared.configure(environment: .preview)
        //
        // Or set up mock authentication:
        //
        //   let token = try await AuthService.signIn(
        //       email: "preview@example.com",
        //       password: ProcessInfo.processInfo.environment["PREVIEW_PASSWORD"] ?? ""
        //   )
        //   SessionManager.shared.setToken(token)
        //
        // Or configure a DI container with mock services:
        //
        //   Container.shared.register(NetworkService.self) { MockNetworkService() }
        //   Container.shared.register(ImageLoader.self) { MockImageLoader() }

        print("[ToDoPreviewSetup] setUp() called — this runs once per session")
    }

    public static func wrap(_ content: AnyView) -> AnyView {
        AnyView(
            content
                .environment(\.appTheme, .brand)
                .tint(AppTheme.brand.accentColor)
        )
    }
}
