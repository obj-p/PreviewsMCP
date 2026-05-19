// Phase-1 v2 Swift source. Same shape as v1, different literal —
// this is the "function override" body. Re-compiled to a second
// `.o`, added to the same LLJIT alongside v1's image, and looked
// up after v1's call to demonstrate hot-swap.

@_cdecl("greet")
public func greet() {
    print("hello from swift v2")
}
