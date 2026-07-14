import SwiftUI

/// Integration test fixture for live-window snapshots (#346).
///
/// Fills the window with a solid color that flips from blue to red shortly
/// after the view appears — a post-render state change with NO source edit and
/// NO recompile. The render-time PNG captures the pre-flip blue; a live snapshot
/// of the visible window must instead reflect the post-flip red. Used by
/// `MacOSLiveSnapshotTests` to prove `preview_snapshot` reads the live window.
struct LiveSnapshotProbe: View {
    @State private var flipped = false

    var body: some View {
        (flipped ? Color(red: 1, green: 0, blue: 0) : Color(red: 0, green: 0, blue: 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    flipped = true
                }
            }
    }
}

#Preview {
    LiveSnapshotProbe()
}
