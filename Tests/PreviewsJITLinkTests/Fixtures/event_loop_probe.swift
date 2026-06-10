import AppKit

nonisolated(unsafe) var observedAppDefinedEvent = false

@_cdecl("event_pump_install")
public func event_pump_install() -> Int32 {
    NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
        observedAppDefinedEvent = true
        return event
    }
    guard
        let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
    else { return -1 }
    NSApplication.shared.postEvent(event, atStart: false)
    return 1
}

@_cdecl("event_pump_check")
public func event_pump_check() -> Int32 {
    observedAppDefinedEvent ? 1 : 0
}
