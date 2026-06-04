import SwiftUI

struct StableView: View {
    let label: String
    var body: some View {
        Text(label)
    }
}

internal func stableInset() -> CGFloat { 1 }

private struct FilePrivateFixture {
    static let note = "private decls never cross a module boundary; at file granularity they move with their file"
}
