// Phase-2 step-1 stretch goal v2 counterpart. Same shape as
// conform_v1.swift, same module name `conform` (set in build.sh),
// so its emitted symbols collide-by-name with conform_v1.swift's.
// Only the witness body differs.

import Greeter

public struct DefaultGreeter: Greeter {
    public init() {}
    public func greet() -> String { "hello from v2 (stretch)" }
}

@_cdecl("makeGreeting")
public func makeGreeting() -> Int {
    let g: any Greeter = DefaultGreeter()
    print(g.greet())
    return 0
}
