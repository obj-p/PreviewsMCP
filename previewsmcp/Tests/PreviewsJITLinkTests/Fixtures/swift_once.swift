let swiftOnceComputed: Int32 = {
    var sum: Int32 = 0
    for i in 1 ... 100 {
        sum &+= Int32(i)
    }
    return sum
}()

@_cdecl("swift_once_value")
public func swiftOnceValue() -> Int32 {
    swiftOnceComputed
}
