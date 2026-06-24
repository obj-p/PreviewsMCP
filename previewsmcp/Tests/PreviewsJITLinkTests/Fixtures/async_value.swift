import Foundation

func computeAsync() async -> Int32 {
    try? await Task.sleep(nanoseconds: 1_000_000)
    return 11
}

@_cdecl("async_value")
public func asyncValue() -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    let slot = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    slot.initialize(to: 0)
    Task {
        slot.pointee = await computeAsync()
        semaphore.signal()
    }
    semaphore.wait()
    let result = slot.pointee
    slot.deinitialize(count: 1)
    slot.deallocate()
    return result
}
