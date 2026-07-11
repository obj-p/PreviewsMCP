// Phase-2 step-3 Swift source. Exercises Swift `async` lowering so
// the emitted Mach-O object contains the async-specific machinery:
//   * `swiftasynccc` lowered code (continuation-passing state machine)
//   * `__TEXT,__swift_async_extended_frame_info` (or whatever section
//     the current swiftc emits for async frame info)
//   * Refs to `swift_task_*` / `swift_continuation_*` /
//     `swift_asyncLet_*` runtime symbols
//
// The C++ host can't directly call a Swift async function (no shared
// task context), so `runAsync` is a `@_cdecl` synchronous wrapper that:
//   1. Spawns a top-level Task that awaits `greetAsync()`.
//   2. Blocks on a DispatchSemaphore until the task signals completion.
//   3. Prints the result from the calling thread.
//
// If JITLink mis-handles the async lowering, expected failure modes
// (in priority order):
//   * Link-time relocation error for an async-specific edge kind.
//   * Lookup succeeds but `swift_task_*` symbols unresolved.
//   * Call hangs forever (continuation never resumes — Task got
//     started but the resume path is broken).
//   * Call crashes in the prologue (async frame pointer mis-set).

import Foundation

public func greetAsync() async -> String {
    // Force a real suspension so the async lowering emits a real
    // continuation point rather than degenerating to a sync tail.
    // Swift may otherwise fast-path return-without-suspend.
    try? await Task.sleep(nanoseconds: 1_000_000)  // 1ms
    return "hello from async v1"
}

@_cdecl("runAsync")
public func runAsync() {
    // We avoid declaring a local class (or any user-defined class) to
    // keep `__DATA,__objc_classlist` empty — JITLink + MachOPlatform
    // does not call objc_registerClassPair on classes from JIT-loaded
    // objects, so doing so currently aborts in libobjc as
    // "Attempt to use unknown class 0x...". The result handoff goes
    // through an UnsafeMutablePointer so the captured closure can
    // write the post-await value without a Sendable diagnostic.
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
