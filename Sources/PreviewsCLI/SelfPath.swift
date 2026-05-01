import Foundation

/// Resolve the running executable's absolute path via `_NSGetExecutablePath`.
/// Authoritative on Darwin — independent of `argv[0]`, which can be relative
/// (`./previewsmcp`), bare when PATH-resolved, or rewritten by the caller via
/// `execve`. The kernel records the real on-disk path at exec time and this
/// call reads it back; no CWD coupling, no caller spoofing.
///
/// Symlinks are resolved so callers comparing against build-system output
/// (e.g., stat-ing `.build/debug/previewsmcp`) see the canonical target —
/// `swift build` produces a logical alias under `.build/debug/` that points
/// at the real binary under `.build/<arch>/debug/`.
///
/// Returns nil only if `_NSGetExecutablePath` itself fails — should not occur
/// on a healthy process.
func resolveRunningBinaryPath() -> String? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [UInt8](repeating: 0, count: Int(size))
    let result = buf.withUnsafeMutableBufferPointer { ptr -> Int32 in
        ptr.baseAddress!.withMemoryRebound(to: CChar.self, capacity: Int(size)) {
            _NSGetExecutablePath($0, &size)
        }
    }
    guard result == 0 else { return nil }
    if let nulIndex = buf.firstIndex(of: 0) {
        buf.removeSubrange(nulIndex..<buf.endIndex)
    }
    let raw = String(decoding: buf, as: UTF8.self)
    return URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
}
