protocol Valued {
    func value() -> Int32
}

struct DefaultValued: Valued {
    func value() -> Int32 { 7 }
}

@_cdecl("witness_value")
public func witnessValue() -> Int32 {
    let v: any Valued = DefaultValued()
    return v.value()
}
