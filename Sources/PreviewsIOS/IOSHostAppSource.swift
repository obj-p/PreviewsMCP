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
            private var literalsTimer: Timer?
            private var lastLiteralsModDate: Date?
            private var touchTimer: Timer?
            private var lastTouchModDate: Date?
            private var currentDylibHandle: UnsafeMutableRawPointer?

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

                if let literalsIndex = args.firstIndex(of: "--literals-file"),
                   literalsIndex + 1 < args.count {
                    watchLiteralsFile(at: args[literalsIndex + 1])
                }

                if let touchIndex = args.firstIndex(of: "--touch-file"),
                   touchIndex + 1 < args.count {
                    initTouchInjection()
                    watchTouchFile(at: args[touchIndex + 1])
                }

                if let elementsIndex = args.firstIndex(of: "--elements-file"),
                   elementsIndex + 1 < args.count {
                    activateAccessibility()
                    watchElementsFile(at: args[elementsIndex + 1])
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
                currentDylibHandle = handle

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
                // Derive ack file path from signal file path
                let ackPath = path.replacingOccurrences(of: "reload-signal.txt", with: "reload-ack.txt")
                lastSignalModDate = modDate(of: path)
                signalTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    guard let newDate = self.modDate(of: path) else { return }
                    guard newDate != self.lastSignalModDate else { return }
                    self.lastSignalModDate = newDate

                    guard let newPath = try? String(contentsOfFile: path, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines) else { return }
                    self.loadPreview(dylibPath: newPath)
                    // Write ack after one RunLoop turn to ensure SwiftUI environment propagation
                    DispatchQueue.main.async {
                        try? "ok".write(toFile: ackPath, atomically: true, encoding: .utf8)
                    }
                }
            }

            private func modDate(of path: String) -> Date? {
                let attrs = try? FileManager.default.attributesOfItem(atPath: path)
                return attrs?[.modificationDate] as? Date
            }

            // MARK: - Literals File Watching (fast path)

            private func watchLiteralsFile(at path: String) {
                lastLiteralsModDate = modDate(of: path)
                literalsTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    guard let newDate = self.modDate(of: path) else { return }
                    guard newDate != self.lastLiteralsModDate else { return }
                    self.lastLiteralsModDate = newDate

                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
                    self.applyLiterals(data)
                }
            }

            // MARK: - Touch Injection via Hammer approach (BKSHIDEvent + IOKit)
            //
            // Creates IOHIDEvent objects and delivers them through UIApplication._enqueueHIDEvent:
            // with BKSHIDEventSetDigitizerInfo to route to the correct window.
            // Runs entirely in-process — no Simulator.app needed, no mouse cursor movement.
            // Based on Lyft's Hammer (github.com/lyft/Hammer).

            // Function pointer types
            private typealias CreateDigitizerEventFn = @convention(c) (
                CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
                Double, Double, Double, Double, Double, Bool, Bool, UInt32
            ) -> UnsafeMutableRawPointer?

            private typealias CreateDigitizerFingerEventFn = @convention(c) (
                CFAllocator?, UInt64, UInt32, UInt32, UInt32,
                Double, Double, Double, Double, Double, Bool, Bool, UInt32
            ) -> UnsafeMutableRawPointer?

            private typealias AppendEventFn = @convention(c) (
                UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32
            ) -> Void

            private typealias SetIntegerValueFn = @convention(c) (
                UnsafeMutableRawPointer, UInt32, Int32
            ) -> Void

            private typealias SetFloatValueFn = @convention(c) (
                UnsafeMutableRawPointer, UInt32, Double
            ) -> Void

            private typealias SetSenderIDFn = @convention(c) (
                UnsafeMutableRawPointer, UInt64
            ) -> Void

            private typealias BKSSetDigitizerInfoFn = @convention(c) (
                UnsafeMutableRawPointer, UInt32, Bool, Bool, CFString?, Double, Float
            ) -> Void

            private var createDigitizerEvent: CreateDigitizerEventFn?
            private var createDigitizerFingerEvent: CreateDigitizerFingerEventFn?
            private var appendEvent: AppendEventFn?
            private var setIntegerValue: SetIntegerValueFn?
            private var setFloatValue: SetFloatValueFn?
            private var setSenderID: SetSenderIDFn?
            private var bksSetDigitizerInfo: BKSSetDigitizerInfoFn?
            private var touchReady = false

            private func initTouchInjection() {
                guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
                    NSLog("PreviewHost: Failed to load IOKit"); return
                }
                guard let bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW) else {
                    NSLog("PreviewHost: Failed to load BackBoardServices"); return
                }

                createDigitizerEvent = unsafeBitCast(dlsym(iokit, "IOHIDEventCreateDigitizerEvent"), to: CreateDigitizerEventFn?.self)
                createDigitizerFingerEvent = unsafeBitCast(dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent"), to: CreateDigitizerFingerEventFn?.self)
                appendEvent = unsafeBitCast(dlsym(iokit, "IOHIDEventAppendEvent"), to: AppendEventFn?.self)
                setIntegerValue = unsafeBitCast(dlsym(iokit, "IOHIDEventSetIntegerValue"), to: SetIntegerValueFn?.self)
                setFloatValue = unsafeBitCast(dlsym(iokit, "IOHIDEventSetFloatValue"), to: SetFloatValueFn?.self)
                setSenderID = unsafeBitCast(dlsym(iokit, "IOHIDEventSetSenderID"), to: SetSenderIDFn?.self)
                bksSetDigitizerInfo = unsafeBitCast(dlsym(bbs, "BKSHIDEventSetDigitizerInfo"), to: BKSSetDigitizerInfoFn?.self)

                touchReady = (createDigitizerEvent != nil && createDigitizerFingerEvent != nil &&
                              appendEvent != nil && setIntegerValue != nil && bksSetDigitizerInfo != nil)

                NSLog("PreviewHost: Touch injection \\(touchReady ? "ready" : "FAILED")")
            }

            private func watchTouchFile(at path: String) {
                lastTouchModDate = modDate(of: path)
                touchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    guard let newDate = self.modDate(of: path) else { return }
                    guard newDate != self.lastTouchModDate else { return }
                    self.lastTouchModDate = newDate

                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                          let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    self.handleTouchCommand(command)
                }
            }

            private func handleTouchCommand(_ command: [String: Any]) {
                guard let action = command["action"] as? String else { return }

                switch action {
                case "tap":
                    guard let x = command["x"] as? Double,
                          let y = command["y"] as? Double else { return }
                    sendTap(x: x, y: y)
                case "swipe":
                    guard let fromX = command["fromX"] as? Double,
                          let fromY = command["fromY"] as? Double,
                          let toX = command["toX"] as? Double,
                          let toY = command["toY"] as? Double else { return }
                    let duration = command["duration"] as? Double ?? 0.3
                    let steps = command["steps"] as? Int ?? 10
                    sendSwipe(fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                              duration: duration, steps: steps)
                default:
                    break
                }
            }

            private func sendTap(x: Double, y: Double) {
                sendTouchEvent(x: x, y: y, phase: .began)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    self.sendTouchEvent(x: x, y: y, phase: .ended)
                }
            }

            private func sendSwipe(fromX: Double, fromY: Double,
                                    toX: Double, toY: Double,
                                    duration: Double, steps: Int) {
                let stepCount = max(steps, 2)
                let interval = duration / Double(stepCount)

                // Touch down at start
                sendTouchEvent(x: fromX, y: fromY, phase: .began)

                // Intermediate moves
                for i in 1..<stepCount {
                    let t = Double(i) / Double(stepCount)
                    let x = fromX + (toX - fromX) * t
                    let y = fromY + (toY - fromY) * t
                    DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                        self.sendTouchEvent(x: x, y: y, phase: .moved)
                    }
                }

                // Touch up at end
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    self.sendTouchEvent(x: toX, y: toY, phase: .ended)
                }
            }

            private enum TouchPhase { case began, moved, ended }

            private func sendTouchEvent(x: Double, y: Double, phase: TouchPhase) {
                guard touchReady,
                      let createParent = createDigitizerEvent,
                      let createFinger = createDigitizerFingerEvent,
                      let append = appendEvent,
                      let setInt = setIntegerValue,
                      let setBKS = bksSetDigitizerInfo else { return }

                let timestamp = mach_absolute_time()
                let isTouching = (phase != .ended)
                let pressure: Double = isTouching ? 1.0 : 0.0

                // Event masks per Hammer:
                // began/ended: .touch | .range (0x03)
                // moved: .position (0x04)
                let fingerMask: UInt32 = (phase == .moved) ? 0x04 : 0x03
                let parentMask: UInt32 = 0x02 // .touch

                // Parent event (hand, transducerType=3)
                guard let parent = createParent(
                    nil, timestamp, 3, 0, 0, parentMask, 0,
                    0, 0, 0, 0, 0, false, isTouching, 0
                ) else { return }

                // Set isDisplayIntegrated
                setInt(parent, 0xB0019, 1)

                // Set sender ID (any non-zero value)
                setSenderID?(parent, 0x0000000123456789)

                // Child finger event
                guard let finger = createFinger(
                    nil, timestamp, 1, 1, fingerMask,
                    x, y, 0, pressure, 0,
                    isTouching, isTouching, 0
                ) else { return }

                // Set radius on finger
                setFloatValue?(finger, 0xB0014, 5.0)  // majorRadius
                setFloatValue?(finger, 0xB0015, 5.0)  // minorRadius

                append(parent, finger, 0)

                // Get window context ID via private _contextId property
                var contextId: UInt32 = 0
                if let w = self.window {
                    let sel = NSSelectorFromString("_contextId")
                    if w.responds(to: sel) {
                        contextId = UInt32(truncatingIfNeeded:
                            Int(bitPattern: w.perform(sel)?.toOpaque()))
                    }
                }

                // Stamp with BKS digitizer info
                setBKS(parent, contextId, false, false, nil, 0, 0)

                // Deliver via UIApplication._enqueueHIDEvent:
                let enqueueSel = NSSelectorFromString("_enqueueHIDEvent:")
                let app = UIApplication.shared
                if app.responds(to: enqueueSel) {
                    let eventObj = Unmanaged<AnyObject>.fromOpaque(parent).takeUnretainedValue()
                    app.perform(enqueueSel, with: eventObj)
                }
            }

            // MARK: - Accessibility Tree Dump

            private var elementsTimer: Timer?
            private var lastElementsModDate: Date?

            private func watchElementsFile(at path: String) {
                lastElementsModDate = modDate(of: path)
                elementsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    guard let newDate = self.modDate(of: path) else { return }
                    guard newDate != self.lastElementsModDate else { return }
                    self.lastElementsModDate = newDate

                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let responsePath = request["responsePath"] as? String else { return }

                    self.dumpAccessibilityTree(to: responsePath)
                }
            }

            private var accessibilityActivated = false

            private func activateAccessibility() {
                guard !accessibilityActivated else { return }
                accessibilityActivated = true
                // Enable accessibility automation mode (what XCTest uses)
                // This makes SwiftUI compute its accessibility tree without VoiceOver
                if let sym = dlsym(dlopen(nil, RTLD_LAZY), "_AXSSetAutomationEnabled") {
                    typealias Fn = @convention(c) (Bool) -> Void
                    let fn = unsafeBitCast(sym, to: Fn.self)
                    fn(true)
                }
            }

            private func dumpAccessibilityTree(to responsePath: String) {
                guard let window = self.window else { return }

                let tree = snapshotElement(window, window: window) ?? ["children": [] as [Any]]
                guard let data = try? JSONSerialization.data(withJSONObject: tree, options: []) else { return }
                try? data.write(to: URL(fileURLWithPath: responsePath), options: .atomic)
            }

            private func snapshotElement(_ element: Any, window: UIWindow) -> [String: Any]? {
                guard let obj = element as? NSObject else { return nil }

                // Leaf: this element IS an accessibility element — capture it
                if obj.isAccessibilityElement {
                    return captureAccessibleNode(element, window: window)
                }

                // Container: walk accessibility children
                var children: [[String: Any]] = []

                let count = obj.accessibilityElementCount()
                if count != NSNotFound && count > 0 {
                    for i in 0..<min(count, 500) {
                        if let child = obj.accessibilityElement(at: i) {
                            if let childNode = snapshotElement(child, window: window) {
                                children.append(childNode)
                            }
                        }
                    }
                } else if let view = element as? UIView {
                    // Fallback: subviews
                    for subview in view.subviews {
                        if let childNode = snapshotElement(subview, window: window) {
                            children.append(childNode)
                        }
                    }
                }

                guard !children.isEmpty else { return nil }

                // Flatten single-child containers to avoid deep nesting
                if children.count == 1 { return children[0] }

                var node: [String: Any] = ["role": "group"]
                if let view = element as? UIView {
                    let frame = view.convert(view.bounds, to: nil)
                    node["frame"] = [
                        "x": Int(frame.origin.x),
                        "y": Int(frame.origin.y),
                        "width": Int(frame.size.width),
                        "height": Int(frame.size.height)
                    ]
                }
                node["children"] = children
                return node
            }

            private func captureAccessibleNode(_ element: Any, window: UIWindow) -> [String: Any] {
                var node: [String: Any] = [:]

                // Frame — normalize all coordinates to window-relative
                if let view = element as? UIView {
                    let frame = view.convert(view.bounds, to: nil)
                    node["frame"] = [
                        "x": Int(frame.origin.x),
                        "y": Int(frame.origin.y),
                        "width": Int(frame.size.width),
                        "height": Int(frame.size.height)
                    ]
                } else if let accElement = element as? NSObject {
                    // accessibilityFrame is in screen coordinates — convert to window
                    let screenFrame = accElement.accessibilityFrame
                    let windowFrame = window.convert(screenFrame, from: nil)
                    node["frame"] = [
                        "x": Int(windowFrame.origin.x),
                        "y": Int(windowFrame.origin.y),
                        "width": Int(windowFrame.size.width),
                        "height": Int(windowFrame.size.height)
                    ]
                }

                if let obj = element as? NSObject {
                    if let label = obj.accessibilityLabel, !label.isEmpty {
                        node["label"] = label
                    }
                    if let value = obj.accessibilityValue, !value.isEmpty {
                        node["value"] = value
                    }
                    if let hint = obj.accessibilityHint, !hint.isEmpty {
                        node["hint"] = hint
                    }
                }
                if let identifiable = element as? UIView,
                   let identifier = identifiable.accessibilityIdentifier, !identifier.isEmpty {
                    node["identifier"] = identifier
                }

                let traits: UIAccessibilityTraits = (element as? NSObject)?.accessibilityTraits ?? []
                var traitNames: [String] = []
                if traits.contains(.button) { traitNames.append("button") }
                if traits.contains(.staticText) { traitNames.append("staticText") }
                if traits.contains(.image) { traitNames.append("image") }
                if traits.contains(.header) { traitNames.append("header") }
                if traits.contains(.link) { traitNames.append("link") }
                if traits.contains(.adjustable) { traitNames.append("adjustable") }
                if traits.contains(.selected) { traitNames.append("selected") }
                if traits.contains(.notEnabled) { traitNames.append("notEnabled") }
                if traits.contains(.searchField) { traitNames.append("searchField") }
                if traits.contains(.tabBar) { traitNames.append("tabBar") }
                if traits.contains(.keyboardKey) { traitNames.append("keyboardKey") }
                if traits.contains(.summaryElement) { traitNames.append("summaryElement") }
                if traits.contains(.updatesFrequently) { traitNames.append("updatesFrequently") }
                if !traitNames.isEmpty {
                    node["traits"] = traitNames
                }

                return node
            }

            // MARK: - Literals

            private func applyLiterals(_ data: Data) {
                guard let handle = currentDylibHandle else { return }
                guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

                for entry in entries {
                    guard let id = entry["id"] as? String,
                          let type = entry["type"] as? String else { continue }

                    switch type {
                    case "string":
                        guard let value = entry["value"] as? String else { continue }
                        guard let sym = dlsym(handle, "designTimeSetString") else { continue }
                        typealias Setter = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
                        let fn = unsafeBitCast(sym, to: Setter.self)
                        id.withCString { idPtr in value.withCString { valPtr in fn(idPtr, valPtr) } }

                    case "integer":
                        guard let value = entry["value"] as? Int else { continue }
                        guard let sym = dlsym(handle, "designTimeSetInteger") else { continue }
                        typealias Setter = @convention(c) (UnsafePointer<CChar>, Int) -> Void
                        let fn = unsafeBitCast(sym, to: Setter.self)
                        id.withCString { idPtr in fn(idPtr, value) }

                    case "float":
                        guard let value = entry["value"] as? Double else { continue }
                        guard let sym = dlsym(handle, "designTimeSetFloat") else { continue }
                        typealias Setter = @convention(c) (UnsafePointer<CChar>, Double) -> Void
                        let fn = unsafeBitCast(sym, to: Setter.self)
                        id.withCString { idPtr in fn(idPtr, value) }

                    case "boolean":
                        guard let value = entry["value"] as? Bool else { continue }
                        guard let sym = dlsym(handle, "designTimeSetBoolean") else { continue }
                        typealias Setter = @convention(c) (UnsafePointer<CChar>, Bool) -> Void
                        let fn = unsafeBitCast(sym, to: Setter.self)
                        id.withCString { idPtr in fn(idPtr, value) }

                    default:
                        break
                    }
                }
            }
        }
        """

    static let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>com.previewsmcp.host</string>
            <key>CFBundleExecutable</key>
            <string>PreviewsMCPHost</string>
            <key>CFBundleName</key>
            <string>PreviewsMCP</string>
            <key>CFBundleDisplayName</key>
            <string>PreviewsMCP</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>CFBundleIconFile</key>
            <string>AppIcon</string>
            <key>CFBundleIcons</key>
            <dict>
                <key>CFBundlePrimaryIcon</key>
                <dict>
                    <key>CFBundleIconFiles</key>
                    <array>
                        <string>AppIcon</string>
                    </array>
                </dict>
            </dict>
            <key>UILaunchStoryboardName</key>
            <string></string>
            <key>LSRequiresIPhoneOS</key>
            <true/>
        </dict>
        </plist>
        """
}
