import Foundation

@_cdecl("main_thread_probe")
public func main_thread_probe() -> Int32 {
    Thread.isMainThread ? 1 : 0
}
