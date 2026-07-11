// Phase-2 step-2 v1 Swift source. Exercises a module-level `let`
// whose initializer is non-trivial. SPIKE FINDING (do not delete):
// swiftc 6.2 does NOT lower this to a Mach-O TLV. It emits a regular
// global (`_$s..._SSvp` in __DATA,__common) + an addressor (`_..._SSvau`)
// that calls `swift_once` on a token (`_..._Wz`) the first time the
// value is read, dispatching to a one-time-init function (`_..._WZ`).
// See `xcrun otool -lV` of this `.o` — there is no `__thread_vars`
// section, and no `_tlv_bootstrap` undefined ref.
//
// We deliberately use a pure-Swift initializer here (no Foundation /
// ObjC bridging) so this object isolates the `swift_once` JIT-link
// lifecycle from ObjC-selector uniquing, which is a SEPARATE coverage
// gap surfaced by host_tlv.cpp's run log when the initializer touches
// `ProcessInfo.processInfo` (selrefs in the JIT-linked image are not
// `sel_registerName`-uniqued, so `objc_msgSend` lands in
// __forwarding__).
//
// The real Mach-O TLV path is exercised by ../swift/tlv_c_v1.c
// (C `_Thread_local`), which DOES emit `__thread_vars`/`__thread_data`
// + a `_tlv_bootstrap` reference.

@_cdecl("readComputed")
public func readComputed() {
    print(computedAtFirstRead)
}

// A non-trivial pure-Swift initializer: a loop the optimizer can't
// fold away (depends on stride). Stays away from Foundation/ObjC.
public let computedAtFirstRead: String = {
    var sum: UInt64 = 0
    for i in 1...100 { sum &+= UInt64(i &* i) }
    return "computed in v1 (sum_of_squares_1_to_100=\(sum))"
}()
