import SwiftUI

struct GenericFixtureView<Value: CustomStringConvertible>: View {
    let value: Value

    var body: some View {
        Text(value.description)
            .padding()
    }
}

extension GenericFixtureView where Value == Int {
    static var fixture: Self {
        Self(value: 42)
    }
}

#Preview("Generic context") {
    GenericFixtureView<Int>.fixture
}
