// Phase-2 step-1 stretch goal: v1 conformance compiled under a
// SHARED module name `conform` so the symbol mangling for
// DefaultGreeter and its witness-table records is identical between
// v1 and v2 (only the call-target bytes for `greet` differ).
//
// This lets the host experiment ask: "if I add v2's image into a
// second JITDylib whose contents define exactly the same symbol
// names as v1's, does dispatch from an already-linked v1 entry
// point pick up v2's bodies?"
//
// The expected answer is NO — JITLink resolves relocations at link
// time, not lookup time. v1's witness-table pointer inside
// DefaultGreeter's metadata is patched to v1's witness table once
// and stays there. But we want to verify this empirically and
// capture what does/doesn't happen.

import Greeter

public struct DefaultGreeter: Greeter {
    public init() {}
    public func greet() -> String { "hello from v1 (stretch)" }
}

@_cdecl("makeGreeting")
public func makeGreeting() -> Int {
    let g: any Greeter = DefaultGreeter()
    print(g.greet())
    return 0
}
