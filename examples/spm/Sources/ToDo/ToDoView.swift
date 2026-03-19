import SwiftUI

/// A view that references `Item` from Item.swift.
/// This preview requires build system integration because `Item`
/// is defined in a different file within the same target.
struct ToDoView: View {
    @State var items: [Item]
    @State var showCompleted = true

    var filteredItems: [Item] {
        showCompleted ? items : items.filter { !$0.isComplete }
    }

    var body: some View {
        NavigationStack {
            List {
                Toggle("Show Completed", isOn: $showCompleted)

                ForEach(filteredItems) { item in
                    ItemRow(item: item, onToggle: {
                        if let idx = items.firstIndex(where: { $0.id == item.id }) {
                            items[idx].isComplete.toggle()
                        }
                    })
                }
            }
            .navigationTitle("My Items")
        }
    }
}

struct ItemRow: View {
    let item: Item
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack {
                Image(systemName: item.isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(item.isComplete ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(item.title)
                        .font(.headline)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ToDoView(items: Item.samples)
}
