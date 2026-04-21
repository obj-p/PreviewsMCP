import SwiftUI
import ToDoExtras

/// A view that imports a sibling target (`ToDoExtras`). Its presence in the
/// ToDo target means compiling any Tier 2 dylib for this package requires
/// linking `libToDoExtras.a`, which in turn requires SPMBuildSystem to add
/// `-L <binPath>` to the compiler flags.
///
/// `PackageScopedLabel` is `package`-scoped in `ToDoExtras`, so the dylib
/// recompile must be invoked with `-package-name spm` for this file to
/// compile — it's the regression guard for the SPMBuildSystem fix that
/// forwards the package identity from `.build/debug.yaml`.
struct Summary: View {
    let items: [Item]

    var body: some View {
        let completed = items.filter(\.isComplete).count
        let remaining = items.count - completed
        VStack(alignment: .leading) {
            Text(ProgressFormatter.summary(completed: completed, total: items.count))
                .font(.headline)
            Text(PackageScopedLabel.remaining(remaining))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview("Summary") {
    Summary(items: Item.samples)
}
