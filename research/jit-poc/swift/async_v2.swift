// Phase-2 step-3 stretch goal. Tests that JITLink + the Swift
// concurrency runtime correctly handle MULTIPLE suspension points
// inside a single async function. async_v1 had one suspend; this
// chains a second `await` so the lowering emits a second continuation
// point and the second resume path actually runs.
//
// If the JITLink-lowered async frame is correct for one suspend but
// not for a chain (e.g. corrupted continuation pointer after the
// first resume), this catches it.

import Foundation

private func partA() async -> String {
    try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
    return "hello"
}

private func partB(_ prefix: String) async -> String {
    try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
    return "\(prefix) from async v2"
}

public func greetAsync() async -> String {
    let a = await partA()
    let b = await partB(a)
    return b
}

@_cdecl("runAsync")
public func runAsync() {
    let sem = DispatchSemaphore(value: 0)
    let slot = UnsafeMutablePointer<String>.allocate(capacity: 1)
    slot.initialize(to: "")
    Task {
        let v = await greetAsync()
        slot.pointee = v
        sem.signal()
    }
    sem.wait()
    print(slot.pointee)
    slot.deinitialize(count: 1)
    slot.deallocate()
}
