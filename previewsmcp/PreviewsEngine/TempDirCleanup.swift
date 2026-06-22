import Foundation

/// Remove temp directories older than 24 hours from previous sessions.
public func cleanupStaleTempDirs() {
    let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent("previewsmcp")
    guard
        let contents = try? FileManager.default.contentsOfDirectory(
            at: tempBase, includingPropertiesForKeys: [.contentModificationDateKey])
    else { return }

    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    for dir in contents {
        guard let attrs = try? dir.resourceValues(forKeys: [.contentModificationDateKey]),
            let modDate = attrs.contentModificationDate,
            modDate < cutoff
        else { continue }
        try? FileManager.default.removeItem(at: dir)
        fputs("Cleaned up stale temp dir: \(dir.lastPathComponent)\n", stderr)
    }
}
