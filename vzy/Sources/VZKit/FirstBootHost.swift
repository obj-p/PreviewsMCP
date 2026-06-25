import AppKit
import Foundation
import Virtualization

/// Boots a VM with a hidden, off-screen `NSWindow` containing a
/// `VZVirtualMachineView`. The window's role is purely to satisfy the
/// requirement (via Apple DTS) that keyboard events posted through
/// `NSApp.postEvent` reach a `VZVirtualMachineView` — i.e., the view
/// must exist in a window in the running `NSApplication`. The window is
/// positioned at `(-10000, -10000)` so it never appears on any visible
/// display, but `NSApp.run()` must be the runloop driver (not
/// `dispatchMain()`), and the calling executable must use
/// `setActivationPolicy(.accessory)` (or `.regular`) for AppKit input
/// machinery to route events.
///
/// Phase 11a delivers only the lifecycle wiring: bring the VM up with
/// the hidden window attached, expose the window/view to a future
/// `KeyboardScripter`, and tear down cleanly. Phase 11b adds the
/// scripted keystroke sequence.
@MainActor
public final class FirstBootHost {
    public let bundle: VMBundle
    public let machine: VZVirtualMachine
    public let window: NSWindow
    public let view: VZVirtualMachineView

    public init(bundle: VMBundle, debugVisible: Bool = false) throws {
        self.bundle = bundle
        let config = try VMConfiguration.build(bundle: bundle)
        let vm = VZVirtualMachine(configuration: config)
        machine = vm

        // `debugVisible` puts the window on the real screen (top-left,
        // 1280x720) so `screencapture` can take before/after screenshots
        // for verifying that `NSEvent.postEvent` keystrokes actually
        // reach the guest. Production mode keeps it at (-10000, -10000)
        // — macOS clips windows to the union of all screens but doesn't
        // refuse to create one outside that union; the view stays
        // active in the window list and routes events normally.
        let frame: NSRect = debugVisible
            ? NSRect(x: 80, y: 80, width: 1280, height: 720)
            : NSRect(x: -10000, y: -10000, width: 1920, height: 1080)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "vz-firstboot"
        window.isReleasedWhenClosed = false
        window.canHide = false

        let viewSize = NSRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let view = VZVirtualMachineView(frame: viewSize)
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        window.contentView = view
        self.window = window
        self.view = view
    }

    /// Make the window known to NSApp's event dispatch — Apple DTS notes
    /// this requires the window to be at least `orderFront` and key. The
    /// window stays at its (-10000, -10000) origin in production, so this
    /// affects only AppKit's internal routing, not the visible UI.
    /// Also makes the view the first responder so synthesized
    /// `keyDown`/`keyUp` events route into `VZVirtualMachineView` rather
    /// than getting eaten by `NSWindow`'s default handlers.
    public func attachToAppKit() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
    }

    /// Convenience for KeyboardScripter consumers — same window + view
    /// the host has, ready for `NSApp.postEvent`.
    public func keyboardScripter() -> KeyboardScripter {
        KeyboardScripter(window: window, view: view)
    }

    public func start(recovery: Bool = false) async throws {
        Log
            .info(
                "starting first-boot host (\(bundle.url.lastPathComponent), hidden window attached\(recovery ? ", into recoveryOS" : ""))"
            )
        attachToAppKit()
        do {
            if recovery {
                let options = VZMacOSVirtualMachineStartOptions()
                options.startUpFromMacOSRecovery = true
                try await machine.start(options: options)
            } else {
                try await machine.start()
            }
        } catch {
            throw VMError("first-boot VZVirtualMachine.start failed", underlying: error)
        }
        Log.info("first-boot VM state = \(machine.state.description)")
    }

    public func requestStop() throws {
        Log.info("first-boot host: requesting guest shutdown")
        do {
            try machine.requestStop()
        } catch {
            throw VMError("first-boot VZVirtualMachine.requestStop failed", underlying: error)
        }
    }

    public func forceStop() async throws {
        Log.info("first-boot host: force-stopping VM")
        do {
            try await machine.stop()
        } catch {
            throw VMError("first-boot VZVirtualMachine.stop failed", underlying: error)
        }
    }

    public func waitForStop(timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while machine.state != .stopped, Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
        }
        if machine.state != .stopped {
            throw VMError(
                "first-boot VM did not reach .stopped within \(Int(timeout))s (state=\(machine.state.description))"
            )
        }
    }

    /// Tear down the window after the VM has stopped. Decoupled from
    /// `forceStop`/`waitForStop` so a caller that wants to inspect the
    /// final framebuffer can do so before we tear down.
    public func close() {
        window.orderOut(nil)
        window.contentView = nil
        view.virtualMachine = nil
    }
}
