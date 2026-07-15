import SharedLocal
import SwiftUI

struct LocalDependencyView: View {
    var body: some View {
        Text(SharedValue.text)
            .padding()
    }
}

#Preview("Local dependency") {
    LocalDependencyView()
}
