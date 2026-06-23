import Foundation

class JITCounter: NSObject {
    @objc func answer() -> Int32 {
        42
    }
}

@_cdecl("objc_class_value")
public func objcClassValue() -> Int32 {
    JITCounter().answer()
}
