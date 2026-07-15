import ObjectiveC
import SwiftUI
import UIKit

/// Holds the rendered preview controller for the SwiftUI window to display.
/// The agent is a SwiftUI `App` so SwiftUI owns the scene -> window -> render
/// binding (matching Apple's XCPreviewAgent); a manually built UIKit window
/// installed after the hosted scene activates renders only intermittently.
final class PreviewStore: ObservableObject {
    static let shared = PreviewStore()
    @Published var contentViewController: UIViewController?
}

/// Called by the JIT'd render entry (over the in-app executor) to install the
/// freshly rendered preview. Exported as a C symbol so the JIT can resolve it.
@_cdecl("previewsmcp_set_preview_vc")
public func previewsmcp_set_preview_vc(_ pointer: UnsafeRawPointer) {
    let viewController = Unmanaged<UIViewController>.fromOpaque(pointer).takeRetainedValue()
    if Thread.isMainThread {
        PreviewStore.shared.contentViewController = viewController
    } else {
        DispatchQueue.main.async { PreviewStore.shared.contentViewController = viewController }
    }
}

private struct PreviewContainer: UIViewControllerRepresentable {
    let viewController: UIViewController
    func makeUIViewController(context _: Context) -> UIViewController {
        viewController
    }

    func updateUIViewController(_: UIViewController, context _: Context) {}
}

private struct PreviewRootView: View {
    @ObservedObject private var store = PreviewStore.shared
    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            if let viewController = store.contentViewController {
                PreviewContainer(viewController: viewController)
                    .id(ObjectIdentifier(viewController))
                    .ignoresSafeArea()
            }
        }
    }
}

@main
struct PreviewAgentApp: App {
    @UIApplicationDelegateAdaptor(PreviewAgentAppDelegate.self) var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup { PreviewRootView() }
            .onChange(of: scenePhase) { _, phase in
                AgentForegroundRedirect.shared.handle(phase)
            }
    }
}

/// Sends a human who opens the agent directly back to the shell, which owns the
/// visible preview. The agent is meant to be hosted by the shell and kept in
/// the background, so a foreground means a direct open.
///
/// A hosted launch briefly flips the agent's scene to `.active` before the
/// shell hosts it (the relaunch flash), so we must not treat that transient as
/// a direct open. When the daemon launches us for hosting (it passes
/// `--agent-sock`), we arm only after the scene has settled to `.background`;
/// a later `.active` is then a real user foreground. A launch with no daemon
/// args is a springboard tap, so we redirect immediately.
private final class AgentForegroundRedirect {
    static let shared = AgentForegroundRedirect()
    private let launchedForHosting = ProcessInfo.processInfo.arguments.contains("--agent-sock")
    private var hostedSettled = false

    func handle(_ phase: ScenePhase) {
        if phase == .background { hostedSettled = true }
        guard phase == .active, !launchedForHosting || hostedSettled else { return }
        foregroundShell()
    }

    /// Foreground the shell without the cross-app consent alert `openURL` would
    /// show. Uses the same private SPI family the shell already relies on;
    /// simulator-only.
    private func foregroundShell() {
        let selector = Selector(("openApplicationWithBundleID:"))
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
              let workspace = workspaceClass.perform(Selector(("defaultWorkspace")))?.takeUnretainedValue(),
              let method = class_getInstanceMethod(type(of: workspace), selector)
        else { return }
        typealias OpenByID = @convention(c) (AnyObject, Selector, NSString) -> Bool
        let open = unsafeBitCast(method_getImplementation(method), to: OpenByID.self)
        _ = open(workspace, selector, "com.previewsmcp.shell" as NSString)
    }
}

class PreviewAgentAppDelegate: UIResponder, UIApplicationDelegate {
    // TCP socket state
    private var socketFD: Int32 = -1
    private var socketReadSource: DispatchSourceRead?
    private var socketReadBuffer = Data()

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        let args = ProcessInfo.processInfo.arguments

        // The in-process ORC executor links objects pushed by the daemon over the
        // EPC socket — there is no preview dylib to load.
        if let jitPortIndex = args.firstIndex(of: "--jit-port"),
           jitPortIndex + 1 < args.count,
           let jitPort = UInt16(args[jitPortIndex + 1])
        {
            startJITExecutor(port: jitPort)
        }

        initTouchInjection()
        activateAccessibility()

        // Bind the hosting-handshake socket before connecting the JSON channel.
        // The daemon waits for that JSON connection before launching the shell,
        // so binding first guarantees the socket exists when the shell connects.
        if let sockIndex = args.firstIndex(of: "--agent-sock"),
           sockIndex + 1 < args.count
        {
            startAgentSocket(path: args[sockIndex + 1])
        }

        if let portIndex = args.firstIndex(of: "--port"),
           portIndex + 1 < args.count,
           let port = UInt16(args[portIndex + 1])
        {
            connectToServer(port: port)
        }

        sendLifecycle("didFinishLaunching")
        return true
    }

    /// Lifecycle breadcrumb (flash detector): report whether the agent comes to
    /// the foreground. A shell-hosted agent must stay non-foreground; a self-
    /// foregrounding launch (the relaunch flash) shows up here as `active`.
    func applicationDidBecomeActive(_: UIApplication) {
        sendLifecycle("didBecomeActive")
    }

    func applicationDidEnterBackground(_: UIApplication) {
        sendLifecycle("didEnterBackground")
    }

    private func sendLifecycle(_ phase: String) {
        let state = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        sendResponse(["type": "lifecycle", "phase": phase, "state": state])
    }

    /// The visible window is owned by SwiftUI's WindowGroup. The touch and
    /// accessibility paths look it up dynamically rather than holding a ref.
    func currentWindow() -> UIWindow? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// Connect back to the daemon's EPC listener and run the in-process ORC
    /// executor. Runs on a detached thread so the SimpleRemoteEPCServer can
    /// block on the socket while the UIApplication run loop stays live on main
    /// (run_on_main dispatches to it).
    private func startJITExecutor(port: UInt16) {
        Thread.detachNewThread { [weak self] in
            let fd = Self.connectLoopback(port: port)
            guard fd >= 0 else {
                NSLog("PreviewAgent: JIT executor failed to connect on port \(port)")
                self?.reportJITError(stage: "connect", code: -1)
                return
            }
            let rc = previewsmcp_ios_executor_start(fd, fd)
            // rc == 1 is an ORC server setup failure (the fd connected but the
            // executor never came up). rc == 2 / 0 fire on disconnect during
            // normal teardown, so reporting them would be a false positive.
            if rc == 1 {
                NSLog("PreviewAgent: JIT executor setup failed (rc=\(rc))")
                self?.reportJITError(stage: "executor", code: rc)
            }
        }
    }

    /// Report an in-app JIT failure to the daemon over the JSON channel. The
    /// executor thread can fail before `connectToServer` binds the socket, so
    /// stash the breadcrumb and flush it once the channel is up.
    private var pendingJITError: [String: Any]?

    private func reportJITError(stage: String, code: Int32) {
        DispatchQueue.main.async {
            let msg: [String: Any] = ["type": "jitError", "stage": stage, "code": Int(code)]
            if self.socketFD >= 0 {
                self.sendResponse(msg)
            } else {
                self.pendingJITError = msg
            }
        }
    }

    private func flushPendingJITError() {
        guard let pending = pendingJITError else { return }
        pendingJITError = nil
        sendResponse(pending)
    }

    private static func connectLoopback(port: UInt16) -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return -1
        }
        return fd
    }

    // MARK: - TCP Socket Client

    private func connectToServer(port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("PreviewAgent: Failed to create socket")
            return
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            NSLog("PreviewAgent: Failed to connect to server on port \(port)")
            Darwin.close(fd)
            return
        }

        socketFD = fd
        NSLog("PreviewAgent: Connected to server on port \(port)")
        startReadLoop()
        startMemoryReporting()
        flushPendingJITError()
    }

    // MARK: - Hosted-scene handshake socket

    /// Unix-domain socket the shell connects to during the cross-process
    /// scene-hosting handshake. The shell reads this process's audit token off
    /// the peer connection (getsockopt LOCAL_PEERTOKEN) and registers it with
    /// FrontBoard so it can route a hosted scene to us. We only accept and hold
    /// the connection open; no bytes are exchanged.
    private var agentSocketFD: Int32 = -1

    private func startAgentSocket(path: String) {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("PreviewAgent: agent socket create failed")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { dst in
                _ = path.withCString { strncpy(dst, $0, pathCapacity - 1) }
            }
        }

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            NSLog("PreviewAgent: agent socket bind failed errno=\(errno)")
            Darwin.close(fd)
            return
        }

        Darwin.listen(fd, 8)
        agentSocketFD = fd
        NSLog("PreviewAgent: agent socket listening at \(path)")

        Thread.detachNewThread {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { break }
                NSLog("PreviewAgent: agent socket client accepted")
            }
        }
    }

    /// Report resident memory to the daemon once a second over the JSON channel.
    /// The daemon exposes it as an observability metric (`agentRSS`). Sends run on
    /// the main queue so they never interleave with response writes on the same socket.
    private var memoryTimer: DispatchSourceTimer?

    private func startMemoryReporting() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            sendResponse(["type": "memory", "rss": Int(currentRSSBytes())])
        }
        timer.resume()
        memoryTimer = timer
    }

    private func currentRSSBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private func startReadLoop() {
        let fd = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            let n = Darwin.read(fd, &buf, buf.count)
            if n > 0 {
                let data = Data(buf[0 ..< n])
                DispatchQueue.main.async {
                    self?.processIncomingData(data)
                }
            } else if n == 0 {
                NSLog("PreviewAgent: Server disconnected")
            }
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        socketReadSource = source
    }

    private func processIncomingData(_ data: Data) {
        socketReadBuffer.append(data)
        while let newlineIndex = socketReadBuffer.firstIndex(of: 0x0A) {
            let lineData = Data(socketReadBuffer[socketReadBuffer.startIndex ..< newlineIndex])
            socketReadBuffer = Data(socketReadBuffer[(newlineIndex + 1)...])

            guard let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = message["type"] as? String
            else { continue }

            handleMessage(message, type: type)
        }
    }

    private func handleMessage(_ msg: [String: Any], type: String) {
        switch type {
        case "touch":
            handleTouchCommand(msg)

        case "elements":
            guard let window = currentWindow() else { return }
            let tree = snapshotElement(window, window: window) ?? ["children": [] as [Any]]
            var response: [String: Any] = ["type": "elementsResponse", "tree": tree]
            if let id = msg["id"] { response["id"] = id }
            sendResponse(response)

        default:
            break
        }
    }

    private func sendResponse(_ dict: [String: Any]) {
        guard socketFD >= 0,
              var data = try? JSONSerialization.data(withJSONObject: dict)
        else { return }
        data.append(0x0A) // newline
        let fd = socketFD
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var remaining = buf.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(fd, base + offset, remaining)
                if n <= 0 { break }
                offset += n
                remaining -= n
            }
        }
    }

    // MARK: - Touch Injection via Hammer approach (BKSHIDEvent + IOKit)

    //
    // Creates IOHIDEvent objects and delivers them through UIApplication._enqueueHIDEvent:
    // with BKSHIDEventSetDigitizerInfo to route to the correct window.
    // Runs entirely in-process — no Simulator.app needed, no mouse cursor movement.
    // Based on Lyft's Hammer (github.com/lyft/Hammer).

    /// Function pointer types
    private typealias CreateDigitizerEventFn =
        @convention(c) (
            CFAllocator?, UInt64, UInt32, UInt32, UInt32, UInt32, UInt32,
            Double, Double, Double, Double, Double, Bool, Bool, UInt32
        ) -> UnsafeMutableRawPointer?

    private typealias CreateDigitizerFingerEventFn =
        @convention(c) (
            CFAllocator?, UInt64, UInt32, UInt32, UInt32,
            Double, Double, Double, Double, Double, Bool, Bool, UInt32
        ) -> UnsafeMutableRawPointer?

    private typealias AppendEventFn =
        @convention(c) (
            UnsafeMutableRawPointer, UnsafeMutableRawPointer, UInt32
        ) -> Void

    private typealias SetIntegerValueFn =
        @convention(c) (
            UnsafeMutableRawPointer, UInt32, Int32
        ) -> Void

    private typealias SetFloatValueFn =
        @convention(c) (
            UnsafeMutableRawPointer, UInt32, Double
        ) -> Void

    private typealias SetSenderIDFn =
        @convention(c) (
            UnsafeMutableRawPointer, UInt64
        ) -> Void

    private typealias BKSSetDigitizerInfoFn =
        @convention(c) (
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
            NSLog("PreviewAgent: Failed to load IOKit"); return
        }
        guard
            let bbs = dlopen(
                "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW
            )
        else {
            NSLog("PreviewAgent: Failed to load BackBoardServices"); return
        }

        createDigitizerEvent = unsafeBitCast(
            dlsym(iokit, "IOHIDEventCreateDigitizerEvent"), to: CreateDigitizerEventFn?.self
        )
        createDigitizerFingerEvent = unsafeBitCast(
            dlsym(iokit, "IOHIDEventCreateDigitizerFingerEvent"), to: CreateDigitizerFingerEventFn?.self
        )
        appendEvent = unsafeBitCast(dlsym(iokit, "IOHIDEventAppendEvent"), to: AppendEventFn?.self)
        setIntegerValue = unsafeBitCast(dlsym(iokit, "IOHIDEventSetIntegerValue"), to: SetIntegerValueFn?.self)
        setFloatValue = unsafeBitCast(dlsym(iokit, "IOHIDEventSetFloatValue"), to: SetFloatValueFn?.self)
        setSenderID = unsafeBitCast(dlsym(iokit, "IOHIDEventSetSenderID"), to: SetSenderIDFn?.self)
        bksSetDigitizerInfo = unsafeBitCast(dlsym(bbs, "BKSHIDEventSetDigitizerInfo"), to: BKSSetDigitizerInfoFn?.self)

        touchReady =
            (createDigitizerEvent != nil && createDigitizerFingerEvent != nil && appendEvent != nil
                && setIntegerValue != nil && bksSetDigitizerInfo != nil)

        NSLog("PreviewAgent: Touch injection \(touchReady ? "ready" : "FAILED")")
    }

    private func handleTouchCommand(_ command: [String: Any]) {
        guard let action = command["action"] as? String else { return }

        // Ack after the last scheduled touch phase so the host's
        // acknowledged round-trip means "events injected", not "bytes
        // buffered". Commands without an id (older hosts) get no ack.
        let injectionDeadline: Double
        switch action {
        case "tap":
            guard let x = command["x"] as? Double,
                  let y = command["y"] as? Double
            else { return }
            sendTap(x: x, y: y)
            injectionDeadline = 0.08
        case "swipe":
            guard let fromX = command["fromX"] as? Double,
                  let fromY = command["fromY"] as? Double,
                  let toX = command["toX"] as? Double,
                  let toY = command["toY"] as? Double
            else { return }
            let duration = command["duration"] as? Double ?? 0.3
            let steps = command["steps"] as? Int ?? 10
            sendSwipe(
                fromX: fromX, fromY: fromY, toX: toX, toY: toY,
                duration: duration, steps: steps
            )
            injectionDeadline = duration + 0.05
        default:
            return
        }

        if let id = command["id"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + injectionDeadline) {
                self.sendResponse(["type": "touchResponse", "id": id])
            }
        }
    }

    private func sendTap(x: Double, y: Double) {
        sendTouchEvent(x: x, y: y, phase: .began)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            self.sendTouchEvent(x: x, y: y, phase: .ended)
        }
    }

    private func sendSwipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        duration: Double, steps: Int
    ) {
        let stepCount = max(steps, 2)
        let interval = duration / Double(stepCount)

        // Touch down at start
        sendTouchEvent(x: fromX, y: fromY, phase: .began)

        // Intermediate moves
        for i in 1 ..< stepCount {
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
              let setBKS = bksSetDigitizerInfo
        else { return }

        let timestamp = mach_absolute_time()
        let isTouching = (phase != .ended)
        let pressure: Double = isTouching ? 1.0 : 0.0

        // Event masks per Hammer:
        // began/ended: .touch | .range (0x03)
        // moved: .position (0x04)
        let fingerMask: UInt32 = (phase == .moved) ? 0x04 : 0x03
        let parentMask: UInt32 = 0x02 // .touch

        // Parent event (hand, transducerType=3)
        guard
            let parent = createParent(
                nil, timestamp, 3, 0, 0, parentMask, 0,
                0, 0, 0, 0, 0, false, isTouching, 0
            )
        else { return }

        // Set isDisplayIntegrated
        setInt(parent, 0xB0019, 1)

        // Set sender ID (any non-zero value)
        setSenderID?(parent, 0x0000_0001_2345_6789)

        // Child finger event
        guard
            let finger = createFinger(
                nil, timestamp, 1, 1, fingerMask,
                x, y, 0, pressure, 0,
                isTouching, isTouching, 0
            )
        else { return }

        // Set radius on finger
        setFloatValue?(finger, 0xB0014, 5.0) // majorRadius
        setFloatValue?(finger, 0xB0015, 5.0) // minorRadius

        append(parent, finger, 0)

        // Get window context ID via private _contextId property
        var contextId: UInt32 = 0
        if let w = currentWindow() {
            let sel = NSSelectorFromString("_contextId")
            if w.responds(to: sel) {
                contextId = UInt32(
                    truncatingIfNeeded:
                    Int(bitPattern: w.perform(sel)?.toOpaque())
                )
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

    private func snapshotElement(_ element: Any, window: UIWindow) -> [String: Any]? {
        guard let obj = element as? NSObject else { return nil }

        // Leaf: this element IS an accessibility element — capture it
        if obj.isAccessibilityElement {
            return captureAccessibleNode(element, window: window)
        }

        // Container: walk accessibility children
        var children: [[String: Any]] = []

        let count = obj.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            for i in 0 ..< min(count, 500) {
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
                "height": Int(frame.size.height),
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
                "height": Int(frame.size.height),
            ]
        } else if let accElement = element as? NSObject {
            // accessibilityFrame is in screen coordinates — convert to window
            let screenFrame = accElement.accessibilityFrame
            let windowFrame = window.convert(screenFrame, from: nil)
            node["frame"] = [
                "x": Int(windowFrame.origin.x),
                "y": Int(windowFrame.origin.y),
                "width": Int(windowFrame.size.width),
                "height": Int(windowFrame.size.height),
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
           let identifier = identifiable.accessibilityIdentifier, !identifier.isEmpty
        {
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
}
