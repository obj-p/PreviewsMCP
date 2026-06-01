protocol Castable {
    func value() -> Int32
}

struct DefaultCastable: Castable {
    func value() -> Int32 { 9 }
}

@_cdecl("dynamic_cast_value")
public func dynamicCastValue() -> Int32 {
    let boxed: Any = DefaultCastable()
    guard let castable = boxed as? Castable else { return -1 }
    return castable.value()
}
