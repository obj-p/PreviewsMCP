import SwiftUI

protocol CompilerSettingMessageProviding {
    var message: String { get }
}

private struct CompilerSettingMessage: CompilerSettingMessageProviding {
    let message: String
}

struct CompilerSettingsView: View {
    private let provider: any CompilerSettingMessageProviding = CompilerSettingMessage(
        message: "ExistentialAny enabled"
    )

    var body: some View {
        VStack(spacing: 8) {
            Text(provider.message)
            #if COMPILER_SETTINGS_PRESENT
                Text("Conditional Swift setting present")
            #else
                #error("COMPILER_SETTINGS_PRESENT was not forwarded to the compile")
            #endif
        }
        .padding()
    }
}

#Preview("Compiler settings only") {
    CompilerSettingsView()
}
