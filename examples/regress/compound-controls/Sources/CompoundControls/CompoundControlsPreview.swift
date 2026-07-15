import SwiftUI

struct CompoundControlsView: View {
    @State private var rowToggle = false
    @State private var trailingToggle = false
    @State private var duplicateOne = false
    @State private var duplicateTwo = true
    @State private var sliderValue = 0.25
    @State private var pickerValue = "One"
    @State private var text = "Editable"
    @State private var detailsExpanded = false
    @State private var buttonCount = 0

    var body: some View {
        Form {
            Section("Row-sized controls") {
                Toggle("Standard row toggle", isOn: $rowToggle)
                    .accessibilityIdentifier("standard-row-toggle")

                HStack {
                    Label("Trailing control", systemImage: "switch.2")
                    Spacer()
                    Toggle("Trailing control", isOn: $trailingToggle)
                        .labelsHidden()
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("trailing-toggle-row")

                Toggle("Duplicate", isOn: $duplicateOne)
                    .accessibilityIdentifier("duplicate-toggle-one")
                Toggle("Duplicate", isOn: $duplicateTwo)
                    .accessibilityIdentifier("duplicate-toggle-two")

                Toggle("Disabled toggle", isOn: .constant(false))
                    .disabled(true)
                    .accessibilityIdentifier("disabled-toggle")
            }

            Section("Other semantics") {
                Button {
                    buttonCount += 1
                } label: {
                    HStack {
                        Text("Inset hit target")
                        Spacer()
                        Text("\(buttonCount)")
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("inset-button")

                Slider(value: $sliderValue)
                    .accessibilityLabel("Fixture slider")
                    .accessibilityIdentifier("fixture-slider")

                Picker("Fixture picker", selection: $pickerValue) {
                    Text("One").tag("One")
                    Text("Two").tag("Two")
                }
                .accessibilityIdentifier("fixture-picker")

                TextField("Fixture text field", text: $text)
                    .accessibilityIdentifier("fixture-text-field")

                DisclosureGroup("Details", isExpanded: $detailsExpanded) {
                    Button("Nested action") {
                        buttonCount += 10
                    }
                    .accessibilityIdentifier("nested-action")
                }
                .accessibilityIdentifier("details-disclosure")
            }

            Section("Scroll boundary") {
                ForEach(
                    [
                        "Spacer row zero",
                        "Spacer row one",
                        "Spacer row two",
                        "Spacer row three",
                        "Spacer row four",
                        "Spacer row five",
                        "Spacer row six",
                        "Spacer row seven",
                        "Spacer row eight",
                        "Spacer row nine",
                        "Spacer row ten",
                        "Spacer row eleven",
                    ],
                    id: \.self
                ) { label in
                    Text(label)
                }
                Button("Off-screen action") {
                    buttonCount += 100
                }
                .accessibilityIdentifier("offscreen-action")
            }
        }
    }
}

#Preview("Compound controls") {
    CompoundControlsView()
}

#Preview("Large accessibility text") {
    CompoundControlsView()
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Transformed controls") {
    CompoundControlsView()
        .scaleEffect(0.9)
        .rotationEffect(.degrees(4))
}
