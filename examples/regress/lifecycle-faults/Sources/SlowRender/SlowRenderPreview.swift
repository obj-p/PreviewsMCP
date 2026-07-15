import Foundation
import SwiftUI

struct SlowRenderView: View {
    init() {
        Thread.sleep(forTimeInterval: 8)
    }

    var body: some View {
        Text("Slow render completed")
            .padding()
    }
}

#Preview("Eight-second render") {
    SlowRenderView()
}
