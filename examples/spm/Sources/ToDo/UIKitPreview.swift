#if canImport(UIKit)
import SwiftUI
import UIKit

/// UIKit preview exercising PreviewsMCP's auto-bridging of UIView bodies.
/// The `#Preview` block returns a `UIView`, which PreviewsMCP wraps in a
/// `UIViewRepresentable` via overload resolution in the generated bridge —
/// mirroring Xcode's first-party `#Preview` macro behavior for UIKit.
final class ExampleLabelView: UIView {
    init(text: String) {
        super.init(frame: .zero)
        backgroundColor = .systemYellow
        let label = UILabel()
        label.text = text
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

#Preview("UIKit label") {
    ExampleLabelView(text: "Hello from UIKit")
}
#endif
