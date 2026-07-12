import AppKit
import CoreFoundation
import Foundation

// #391 DETERMINISTIC control-starvation repro (diagnostic; do not merge). Proves
// worker-a's mechanism: the posted .applicationDefined event flushes only inside
// _DPSNextEvent, reached only when CFRunLoopRunInMode RETURNS to it (on a source1
// or a timer) — NEVER on a dispatch-main drain, which CFRunLoop services inline.
// Keeping the main dispatch queue continuously fed starves _DPSNextEvent of turns
// while runOnMain (a dispatch-main block) keeps answering. A repeating timer
// forces the return and rescues delivery.

nonisolated(unsafe) var starveObserved = false
nonisolated(unsafe) var starveRunning = false
nonisolated(unsafe) var loopCycles: Int32 = 0
nonisolated(unsafe) var rescueTimer: Timer?

private func pumpBusy() {
    DispatchQueue.main.async {
        guard starveRunning else { return }
        // Re-enqueue FIRST so the main-queue source is already ready when this
        // block returns: CFRunLoop keeps draining dispatch inline and never
        // unwinds to _DPSNextEvent (no BeforeWaiting). The short busy span keeps
        // the queue continuously fed while still letting a runOnMain
        // dispatch_sync interleave FIFO (proving dispatch answers while the
        // posted event starves).
        pumpBusy()
        let end = Date().timeIntervalSince1970 + 0.003
        while Date().timeIntervalSince1970 < end {}
    }
}

@_cdecl("starve_install")
public func starve_install() -> Int32 {
    NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
        starveObserved = true
        return event
    }
    // BeforeWaiting fires when the run loop completes a cycle and is about to
    // sleep — a proxy for _DPSNextEvent regaining control. Frozen during the
    // wedge; ticks once the timer forces returns.
    let obs = CFRunLoopObserverCreateWithHandler(
        nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { _, _ in loopCycles += 1 }
    CFRunLoopAddObserver(CFRunLoopGetCurrent(), obs, .defaultMode)

    guard
        let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        )
    else { return -1 }
    NSApplication.shared.postEvent(event, atStart: false)

    starveRunning = true
    pumpBusy()
    return 1
}

@_cdecl("starve_check")
public func starve_check() -> Int32 { starveObserved ? 1 : 0 }

@_cdecl("starve_loop_cycles")
public func starve_loop_cycles() -> Int32 { loopCycles }

// The FIX under test: a repeating timer in the mode [NSApp run] pumps (default).
// Each fire forces CFRunLoopRunInMode to return to _DPSNextEvent → the posted
// queue is re-scanned → the event delivers regardless of WindowServer traffic.
@_cdecl("starve_install_timer")
public func starve_install_timer() -> Int32 {
    let t = Timer(timeInterval: 0.1, repeats: true) { _ in }
    RunLoop.current.add(t, forMode: .default)
    rescueTimer = t
    return 1
}

@_cdecl("starve_stop")
public func starve_stop() -> Int32 {
    starveRunning = false
    rescueTimer?.invalidate()
    rescueTimer = nil
    return 1
}
