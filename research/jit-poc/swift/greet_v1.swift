// Phase-1 v1 Swift source. One free function, prints a literal.
// Deliberately avoids module-level state (no TLVs), generics
// (no metadata registration), protocols (no witness tables), and
// async (no swiftasynccc). See SCOPE.md "Out of scope (Phase 1)".
//
// Compiled with `swiftc -emit-object` to a single Mach-O `.o`.

@_cdecl("greet")
public func greet() {
    print("hello from swift v1")
}
