import SwiftUI
import ToDoExtras

/// A view that imports a sibling target (`ToDoExtras`). Its presence in the
/// ToDo target means compiling any Tier 2 dylib for this package requires
/// linking `libToDoExtras.a`, which in turn requires SPMBuildSystem to add
/// `-L <binPath>` to the compiler flags.
struct Summary: View {
    let items: [Item]

    var body: some View {
        let completed = items.filter(\.isComplete).count
        Text(ProgressFormatter.summary(completed: completed, total: items.count))
            .font(.headline)
    }
}

#Preview("Summary") {
    Summary(items: Item.samples)
}
