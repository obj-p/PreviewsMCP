/// Embedded source code for the iOS simulator host app.
/// Compiled at runtime by IOSHostBuilder targeting arm64-apple-ios-simulator.
enum IOSHostAppSource {
    static let code = """
    import UIKit
    import SwiftUI

    @main
    class PreviewHostAppDelegate: UIResponder, UIApplicationDelegate {
        var window: UIWindow?
        private var retainedControllers: [UIViewController] = []
        private var signalTimer: Timer?
        private var lastSignalModDate: Date?

        func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
        ) -> Bool {
            let window = UIWindow(frame: UIScreen.main.bounds)
            window.backgroundColor = .white
            self.window = window

            let args = ProcessInfo.processInfo.arguments

            guard let dylibIndex = args.firstIndex(of: "--dylib"),
                  dylibIndex + 1 < args.count else {
                let vc = UIViewController()
                vc.view.backgroundColor = .systemRed
                let label = UILabel()
                label.text = "Missing --dylib argument"
                label.textAlignment = .center
                label.frame = vc.view.bounds
                label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                vc.view.addSubview(label)
                window.rootViewController = vc
                window.makeKeyAndVisible()
                return true
            }

            let dylibPath = args[dylibIndex + 1]
            loadPreview(dylibPath: dylibPath)

            if let signalIndex = args.firstIndex(of: "--signal-file"),
               signalIndex + 1 < args.count {
                watchSignalFile(at: args[signalIndex + 1])
            }

            window.makeKeyAndVisible()
            return true
        }

        private func loadPreview(dylibPath: String) {
            guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else {
                let error = String(cString: dlerror())
                showError("dlopen failed: \\(error)")
                return
            }

            guard let sym = dlsym(handle, "createPreviewView") else {
                let error = String(cString: dlerror())
                showError("dlsym failed: \\(error)")
                return
            }

            typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
            let createView = unsafeBitCast(sym, to: CreateFunc.self)
            let rawPtr = createView()
            let viewController = Unmanaged<UIViewController>.fromOpaque(rawPtr).takeRetainedValue()

            if let oldVC = window?.rootViewController {
                retainedControllers.append(oldVC)
            }
            window?.rootViewController = viewController
        }

        private func showError(_ message: String) {
            let vc = UIViewController()
            vc.view.backgroundColor = .systemRed
            let label = UILabel()
            label.text = message
            label.textAlignment = .center
            label.numberOfLines = 0
            label.frame = vc.view.bounds.insetBy(dx: 20, dy: 20)
            label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            vc.view.addSubview(label)

            if let oldVC = window?.rootViewController {
                retainedControllers.append(oldVC)
            }
            window?.rootViewController = vc
        }

        // MARK: - Signal File Watching (hot-reload)

        private func watchSignalFile(at path: String) {
            lastSignalModDate = modDate(of: path)
            signalTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard let newDate = self.modDate(of: path) else { return }
                guard newDate != self.lastSignalModDate else { return }
                self.lastSignalModDate = newDate

                guard let newPath = try? String(contentsOfFile: path, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                self.loadPreview(dylibPath: newPath)
            }
        }

        private func modDate(of path: String) -> Date? {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return attrs?[.modificationDate] as? Date
        }
    }
    """

    static let infoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>com.previews-mcp.ios-host</string>
        <key>CFBundleExecutable</key>
        <string>IOSPreviewHost</string>
        <key>CFBundleName</key>
        <string>IOSPreviewHost</string>
        <key>CFBundleVersion</key>
        <string>1</string>
        <key>CFBundleShortVersionString</key>
        <string>1.0</string>
        <key>UILaunchStoryboardName</key>
        <string></string>
        <key>LSRequiresIPhoneOS</key>
        <true/>
    </dict>
    </plist>
    """
}
