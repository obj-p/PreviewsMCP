import LocalDep
import SwiftUI

/// Preview that references the cross-package `Badge` component from `LocalDep`.
/// This exercises the `.package(path:)` dependency resolution path in
/// SPMBuildSystem — the same code path external third-party packages use.
#Preview("Badges from LocalDep") {
    VStack(spacing: 12) {
        Badge("In Progress", color: .orange)
        Badge("Done", color: .green)
        Badge("Blocked", color: .red)
    }
    .padding()
}
