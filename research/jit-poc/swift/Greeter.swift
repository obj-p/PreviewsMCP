// Phase-2 step-1 shared protocol declaration.
//
// Compiled separately to its own module `Greeter`, producing:
//   - build/Greeter.o          — the protocol descriptor symbol
//                                ($s7Greeter0A0_pMp etc.)
//   - build/Greeter.swiftmodule — interface for v1/v2 to import
//
// Both greeter_v1.swift and greeter_v2.swift `import Greeter` so they
// reference the *same* protocol descriptor as an external symbol.
// JITLink resolves those externals when each version's object is
// added to a JITDylib whose search order includes the JD holding
// Greeter.o.
//
// This is the precondition for the stretch goal: a single protocol
// descriptor that v1's and v2's conformance records both point at.

public protocol Greeter {
    func greet() -> String
}
