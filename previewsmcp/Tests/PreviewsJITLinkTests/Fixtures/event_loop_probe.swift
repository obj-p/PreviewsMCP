import AppKit
import CoreFoundation
import Foundation

nonisolated(unsafe) var observedAppDefinedEvent = false
nonisolated(unsafe) var postTime: Double = 0
nonisolated(unsafe) var fireTime: Double = 0
nonisolated(unsafe) var loopCycles: Int32 = 0

@_cdecl("event_pump_install")
public func event_pump_install() -> Int32 {
    NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
        if !observedAppDefinedEvent {
            observedAppDefinedEvent = true
            fireTime = Date().timeIntervalSince1970
        }
        return event
    }
    // #391 sub-mechanism probe: count BeforeWaiting = the run loop completing a
    // cycle and unwinding toward _DPSNextEvent. If fireDelay tracks the
    // inter-cycle period (cycles get RARER under load), the wedge is mode (ii)
    // reached-less-often — a timer caps the gap and fixes it. If cycles stay
    // fast while fireDelay climbs, it's mode (i) slow-WS-roundtrip — a timer
    // would not help.
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
    postTime = Date().timeIntervalSince1970
    NSApplication.shared.postEvent(event, atStart: false)
    return 1
}

@_cdecl("event_pump_check")
public func event_pump_check() -> Int32 {
    observedAppDefinedEvent ? 1 : 0
}

@_cdecl("event_pump_fire_delay_ms")
public func event_pump_fire_delay_ms() -> Int32 {
    if observedAppDefinedEvent, fireTime > 0, postTime > 0 {
        return Int32(((fireTime - postTime) * 1000).rounded())
    }
    return -1
}

@_cdecl("event_pump_loop_cycles")
public func event_pump_loop_cycles() -> Int32 { loopCycles }
