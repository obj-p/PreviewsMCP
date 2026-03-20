import SwiftUI

/// A view that references `Item` from Item.swift.
/// This preview requires build system integration because `Item`
/// is defined in a different file within the same target.
struct ToDoView: View {
    @State var items: [Item]
    @State var showCompleted = true
    @State var selectedPage = 0

    var filteredItems: [Item] {
        showCompleted ? items : items.filter { !$0.isComplete }
    }

    var completedCount: Int { items.filter(\.isComplete).count }
    var remainingCount: Int { items.filter { !$0.isComplete }.count }

    var body: some View {
        NavigationStack {
            List {
                // Horizontal paged cards — swipe left/right to navigate
                Section {
                    TabView(selection: $selectedPage) {
                        SummaryCard(
                            title: "Progress",
                            value: "\(completedCount)/\(items.count)",
                            detail: "\(remainingCount) remaining",
                            color: .blue
                        ).tag(0)
                        SummaryCard(
                            title: "Next Up",
                            value: items.first { !$0.isComplete }?.title ?? "All done!",
                            detail: "Top priority",
                            color: .orange
                        ).tag(1)
                        SummaryCard(
                            title: "Completed",
                            value: "\(completedCount)",
                            detail: "Keep it up!",
                            color: .green
                        ).tag(2)
                    }
                    #if os(iOS)
                    .tabViewStyle(.page(indexDisplayMode: .always))
                    #endif
                    .frame(height: 120)
                    .listRowInsets(EdgeInsets())
                }

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

struct SummaryCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(color.gradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .padding(.vertical, 8)
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
