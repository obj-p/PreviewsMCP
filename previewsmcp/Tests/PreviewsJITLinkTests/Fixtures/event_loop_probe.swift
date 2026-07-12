import AppKit
import Darwin

nonisolated(unsafe) var observedAppDefinedEvent = false

/// #391 observability: read the agent's drain-timer counters. This fixture is
/// JIT-loaded into the agent process, so dlsym(RTLD_DEFAULT) resolves the
/// executable's exported counters. Fail-soft to -1 when the symbols are absent
/// (e.g. an agent without the drain timer) so the reader never crashes the test.
private func agentCounter(_ symbol: String) -> Int32 {
    guard let sym = dlsym(dlopen(nil, RTLD_NOW), symbol) else { return -1 }
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)()
}

@_cdecl("event_pump_loop_iterations")
public func event_pump_loop_iterations() -> Int32 {
    agentCounter("previewAgentLoopIterations")
}

@_cdecl("event_pump_session_null")
public func event_pump_session_null() -> Int32 {
    agentCounter("previewAgentSessionNull")
}

@_cdecl("event_pump_entered_nsapp_run")
public func event_pump_entered_nsapp_run() -> Int32 {
    agentCounter("previewAgentEnteredNSAppRun")
}

@_cdecl("event_pump_install")
public func event_pump_install() -> Int32 {
    NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
        observedAppDefinedEvent = true
        return event
    }
    guard
        let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        )
    else { return -1 }
    NSApplication.shared.postEvent(event, atStart: false)
    return 1
}

@_cdecl("event_pump_check")
public func event_pump_check() -> Int32 {
    observedAppDefinedEvent ? 1 : 0
}
