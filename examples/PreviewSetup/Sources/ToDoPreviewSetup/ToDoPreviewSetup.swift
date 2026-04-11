import PreviewsSetupKit
import SwiftUI

// MARK: - Preview Environment

/// Observable state created once in setUp() and injected into every preview via wrap().
/// Persists across hot-reload cycles because setUp() runs once per session.
@Observable
final class PreviewEnvironment: @unchecked Sendable {
    static let shared = PreviewEnvironment()

    var userName: String = ""
    var isSubscribed: Bool = false
    var showSummaryCards: Bool = true
    private(set) var isConfigured: Bool = false

    func configure(
        userName: String,
        isSubscribed: Bool,
        showSummaryCards: Bool
    ) {
        self.userName = userName
        self.isSubscribed = isSubscribed
        self.showSummaryCards = showSummaryCards
        self.isConfigured = true
    }
}

private struct PreviewEnvironmentKey: EnvironmentKey {
    static let defaultValue = PreviewEnvironment.shared
}

extension EnvironmentValues {
    var previewEnvironment: PreviewEnvironment {
        get { self[PreviewEnvironmentKey.self] }
        set { self[PreviewEnvironmentKey.self] = newValue }
    }
}

// MARK: - Theme

struct AppTheme: Sendable {
    let accentColor: Color
    let bannerColor: Color

    static let brand = AppTheme(
        accentColor: Color(red: 0.4, green: 0.2, blue: 0.8),
        bannerColor: Color(red: 0.95, green: 0.93, blue: 1.0)
    )
}

// MARK: - Preview Banner

/// A small overlay showing that the setup plugin is active and what mock state is configured.
/// This banner appears at the bottom of every preview — visible proof that setUp() ran.
struct PreviewBanner: View {
    let env: PreviewEnvironment

    var body: some View {
        if env.isConfigured {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.white.opacity(0.9))
                Text(env.userName)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                if env.isSubscribed {
                    Text("PRO")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(AppTheme.brand.accentColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.white, in: Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.brand.accentColor.opacity(0.85), in: Capsule())
        }
    }
}

// MARK: - PreviewSetup conformance

/// Setup target for ToDo app previews.
///
/// Replaces what would otherwise be a separate "dev app" or "micro app".
/// PreviewsMCP builds this package independently — the ToDo app target
/// has no dependency on PreviewsMCP or PreviewsSetupKit.
///
/// `setUp()` runs once when the host app launches. Side effects persist
/// across hot-reload cycles and preview switches.
///
/// `wrap()` runs on every render. Trait overrides from `preview_configure`
/// are applied outside this wrapper.
public struct ToDoPreviewSetup: PreviewSetup {

    public static func setUp() async throws {
        // This runs in a real UIApplication (iOS) or NSApplication (macOS)
        // process — not a sandbox. Real SDK calls work here:
        //
        //   FirebaseApp.configure()
        //   CTFontManagerRegisterFontsForURL(fontURL, .process, nil)
        //   let token = try await AuthService.signIn(...)
        //   Container.shared.register(NetworkService.self) { MockNetworkService() }

        PreviewEnvironment.shared.configure(
            userName: "dev@example.com",
            isSubscribed: true,
            showSummaryCards: true
        )
    }

    public static func wrap(_ content: AnyView) -> AnyView {
        AnyView(
            content
                .environment(\.previewEnvironment, .shared)
                .tint(AppTheme.brand.accentColor)
                .overlay(alignment: .bottom) {
                    PreviewBanner(env: .shared)
                        .padding(.bottom, 8)
                }
        )
    }
}
