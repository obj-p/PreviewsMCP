import Foundation

@_cdecl("objc_selref_value")
public func objcSelrefValue() -> Int32 {
    let formatted = NSString(format: "%d", Int32(42))
    return formatted.intValue
}
