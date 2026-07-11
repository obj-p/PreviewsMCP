// Phase-2 step-1 v2 source.
//
// Same shape as greeter_v1.swift — same protocol import, same
// conforming type name `DefaultGreeter`, same `makeGreeting` cdecl
// symbol — but the witness body returns "hello from v2".
//
// We deliberately keep the conforming type name identical to v1 so
// the conformance descriptor and witness-table symbol mangling
// match between the two objects. That makes step 4 a clean
// "swap in v2's JITDylib, look up the same name" demo, and is also
// the precondition for the stretch goal of replacing v1's
// conformance entry while v1's `makeGreeting` call site is reused.

import Greeter

public struct DefaultGreeter: Greeter {
    public init() {}
    public func greet() -> String { "hello from v2" }
}

@_cdecl("makeGreeting")
public func makeGreeting() -> Int {
    let g: any Greeter = DefaultGreeter()
    print(g.greet())
    return 0
}
