import Foundation
import Lottie

/// A simple model defined in a separate file from the views.
/// Previews that reference this type require build system integration.
struct Item: Identifiable {
    let id: UUID
    var title: String
    let subtitle: String
    var isComplete: Bool

    nonisolated(unsafe) static var samples: [Item] = [
        Item(id: UUID(), title: "Design UI", subtitle: "Create mockups", isComplete: true),
        Item(id: UUID(), title: "Write code", subtitle: "Implement features", isComplete: false),
        Item(id: UUID(), title: "Test", subtitle: "Run test suite", isComplete: false),
        Item(id: UUID(), title: "Ship it", subtitle: "Deploy to production", isComplete: false),
        Item(id: UUID(), title: "Monitor", subtitle: "Watch the dashboards", isComplete: false),
        Item(id: UUID(), title: "Celebrate", subtitle: "Team dinner", isComplete: false),
        Item(id: UUID(), title: "Retro", subtitle: "What went well?", isComplete: false),
        Item(id: UUID(), title: "Plan next", subtitle: "Sprint planning", isComplete: false),
    ]
}
