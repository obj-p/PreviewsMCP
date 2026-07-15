import SwiftUI

@_silgen_name("previewsmcp_fixture_symbol_that_does_not_exist")
private func previewsmcpFixtureMissingSymbol() -> Int32

struct MissingSymbolView: View {
    private let value = previewsmcpFixtureMissingSymbol()

    var body: some View {
        Text("Unexpected value: \(value)")
            .padding()
    }
}

#Preview("Missing JIT symbol") {
    MissingSymbolView()
}
