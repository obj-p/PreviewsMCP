import SwiftUI

/// Integration test fixture for PreviewProvider support.
/// Tests that PreviewsMCP can parse and render PreviewProvider-based previews.
struct ToDoProvider_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ToDoView(items: Item.samples)
                .previewDisplayName("Default")
            ToDoView(items: [])
                .previewDisplayName("Empty State")
        }
    }
}
