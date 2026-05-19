// Phase-2 step-2.5 Swift source. Exercises Foundation/ObjC bridging
// so the emitted Mach-O object contains `__DATA,__objc_selrefs` +
// `__TEXT,__objc_methname` (and `__DATA,__objc_classrefs` /
// `__DATA,__objc_imageinfo`).
//
// Before the ObjCSelrefPlugin: JIT-linking this object and calling
// `touchFoundation` aborts in `__forwarding__` because the selref
// slots hold pointers to the JIT image's own methname cstrings, not
// canonical SELs registered with libobjc.
//
// After the plugin: the selref slots hold `sel_registerName(...)`
// pointers, and `objc_msgSend` works.

import Foundation

@_cdecl("touchFoundation")
public func touchFoundation() {
    let p = ProcessInfo.processInfo
    print("touchFoundation: pid=\(p.processIdentifier)")
}

@_cdecl("touchNSString")
public func touchNSString() {
    // Generalisation test — different selrefs in a different shape.
    // `NSString(format:)` exercises a class-method selref +
    // `description` exercises an instance-method selref via the
    // CustomStringConvertible bridge.
    let s = NSString(format: "ns_v1=%d sum=%d", 7, 7 * 6)
    print("touchNSString: \(s.description)")
}
