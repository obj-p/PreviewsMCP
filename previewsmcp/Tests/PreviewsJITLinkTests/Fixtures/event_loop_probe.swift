import AppKit
import Foundation

nonisolated(unsafe) var observedAppDefinedEvent = false
nonisolated(unsafe) var postTime: Double = 0
nonisolated(unsafe) var fireTime: Double = 0

@_cdecl("event_pump_install")
public func event_pump_install() -> Int32 {
    NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
        if !observedAppDefinedEvent {
            observedAppDefinedEvent = true
            fireTime = Date().timeIntervalSince1970
        }
        return event
    }
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

// #391 timing-neutral diagnostic: post->monitor-fire delay in ms, or -1 if the
// monitor has not fired yet. The fire timestamp is recorded inside the monitor
// closure, which only runs when [NSApp run] actually dispatches the event, so
// this adds no work to agent startup or the run-loop selection path.
@_cdecl("event_pump_fire_delay_ms")
public func event_pump_fire_delay_ms() -> Int32 {
    if observedAppDefinedEvent, fireTime > 0, postTime > 0 {
        return Int32(((fireTime - postTime) * 1000).rounded())
    }
    return -1
}
