#if canImport(UIKit)
    import UIKit

    protocol FixtureViewInstalling {}

    extension FixtureViewInstalling where Self: UIViewController {
        func installFixtureView() {
            view.backgroundColor = .systemBackground
        }
    }

    final class FixtureViewController: UIViewController, FixtureViewInstalling {
        override func viewDidLoad() {
            super.viewDidLoad()
            installFixtureView()
        }
    }
#endif
