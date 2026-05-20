// Phase-2 step-1 v1 source.
//
// Imports the shared `Greeter` protocol module (built separately), so
// the protocol descriptor `$s7Greeter0A0_pMp` is an *external*
// reference in this object. The conformance witness table
// (`$s9greeter_v114DefaultGreeterV0A00B0AAWP`-ish — exact mangling
// depends on swiftc) and `DefaultGreeter`'s value witness table are
// defined here.
//
// `makeGreeting()` uses `any Greeter` to force *dynamic* dispatch
// through the protocol witness table at the `g.greet()` call site —
// not a static call. That's the critical bit: the call site reads
// the witness table at runtime, which is what gets patched in any
// realistic hot-reload.

import Greeter

public struct DefaultGreeter: Greeter {
    public init() {}
    public func greet() -> String { "hello from v1" }
}

@_cdecl("makeGreeting")
public func makeGreeting() -> Int {
    let g: any Greeter = DefaultGreeter()
    print(g.greet())
    return 0
}
