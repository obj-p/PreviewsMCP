import Observation
import SwiftUI

@Observable
final class ToolchainMacroModel {
    var label = "toolchain macro active"
}

struct ToolchainMacroView: View {
    @State private var model = ToolchainMacroModel()

    var body: some View {
        Text(model.label)
            .padding()
    }
}

#Preview("Toolchain macro") {
    ToolchainMacroView()
}
