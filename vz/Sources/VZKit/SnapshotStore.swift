import Darwin
import Foundation

/// Linear named snapshots of a `VMBundle`'s mutable disk state.
///
/// **Model:** snapshot-as-state, not clone-as-VM. Each snapshot is a
/// named directory under `<bundle>/snapshots/<name>/` containing APFS-
/// cloned copies of `disk.img` + `aux.img`. The bundle itself is the
/// "live" state; restoring rewinds the live state to a named snapshot.
///
/// **Mechanism:** Darwin's `clonefile(2)` (the syscall behind `cp -c`).
/// APFS keeps extents shared between source and destination until one
/// side writes — so taking a snapshot of a 64 GiB sparse disk costs
/// near-zero real disk regardless of how full the disk is, and
/// restoring is similarly instant.
///
/// **Invariants:**
/// - The VM must NOT be running when taking or restoring a snapshot
///   (`<bundle>/running.pid` is the gate). Cloning a disk image while
///   the guest is writing produces a torn copy.
/// - Snapshots only carry `disk.img` + `aux.img`. The other bundle
///   files (`config.json`, `hardware-model.bin`, `machine-identifier.bin`,
///   the SSH keypair) are user-managed and don't change at runtime.
public enum SnapshotStore {
    /// Snapshot of a bundle as it sits on disk.
    public struct Snapshot: Sendable, Equatable {
        public let name: String
        public let directory: URL
        public let createdAt: Date
    }

    /// `<bundle>/snapshots/`.
    public static func snapshotsDirectory(for bundle: VMBundle) -> URL {
        bundle.url.appending(path: "snapshots")
    }

    /// `<bundle>/snapshots/<name>/`.
    public static func directory(for bundle: VMBundle, name: String) -> URL {
        snapshotsDirectory(for: bundle).appending(path: name)
    }

    /// Take a snapshot. Refuses if the VM is running or the snapshot
    /// already exists (caller must `delete` first to overwrite).
    public static func take(name: String, of bundle: VMBundle) throws -> Snapshot {
        try ensureSnapshotName(name)
        try ensureVMNotRunning(bundle: bundle)

        let target = directory(for: bundle, name: name)
        if FileManager.default.fileExists(atPath: target.path) {
            throw VMError("snapshot '\(name)' already exists at \(target.path)")
        }
        try FileManager.default.createDirectory(
            at: target, withIntermediateDirectories: true)

        do {
            try clone(from: bundle.diskImageURL, to: target.appending(path: "disk.img"))
            try clone(from: bundle.auxStorageURL, to: target.appending(path: "aux.img"))
        } catch {
            // Clean up partial snapshot dir so the next take doesn't
            // see the half-finished state.
            try? FileManager.default.removeItem(at: target)
            throw error
        }

        Log.info("snapshot '\(name)' taken at \(target.path)")
        return Snapshot(name: name, directory: target, createdAt: Date())
    }

    /// Restore a snapshot. Overwrites the bundle's `disk.img` and
    /// `aux.img` with cloned copies of the snapshot's. Refuses if the
    /// VM is running.
    public static func restore(name: String, in bundle: VMBundle) throws {
        try ensureSnapshotName(name)
        try ensureVMNotRunning(bundle: bundle)

        let snapshot = directory(for: bundle, name: name)
        let snapshotDisk = snapshot.appending(path: "disk.img")
        let snapshotAux = snapshot.appending(path: "aux.img")
        guard FileManager.default.fileExists(atPath: snapshotDisk.path),
              FileManager.default.fileExists(atPath: snapshotAux.path) else {
            throw VMError("snapshot '\(name)' missing or incomplete at \(snapshot.path)")
        }

        // Remove the live files first; `clonefile` refuses if the
        // destination already exists.
        try? FileManager.default.removeItem(at: bundle.diskImageURL)
        try? FileManager.default.removeItem(at: bundle.auxStorageURL)

        do {
            try clone(from: snapshotDisk, to: bundle.diskImageURL)
            try clone(from: snapshotAux, to: bundle.auxStorageURL)
        } catch {
            // If we fail mid-restore, the bundle is in a broken state.
            // The caller can re-restore; we make sure they know.
            throw VMError(
                "RESTORE FAILED mid-way — bundle's disk.img/aux.img may be missing. " +
                "Re-run `vz snapshot restore \(name)`.",
                underlying: error)
        }

        Log.info("snapshot '\(name)' restored to \(bundle.url.path)")
    }

    /// List all snapshots in `bundle.url/snapshots/`, sorted by name.
    public static func list(in bundle: VMBundle) throws -> [Snapshot] {
        let dir = snapshotsDirectory(for: bundle)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: dir.path)
        } catch {
            throw VMError("could not list \(dir.path)", underlying: error)
        }

        return entries.compactMap { name in
            let subdir = dir.appending(path: name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subdir.path, isDirectory: &isDir),
                  isDir.boolValue else { return nil }
            let attrs = try? fm.attributesOfItem(atPath: subdir.path)
            let created = (attrs?[.creationDate] as? Date) ?? Date.distantPast
            return Snapshot(name: name, directory: subdir, createdAt: created)
        }.sorted { $0.name < $1.name }
    }

    /// Delete a snapshot directory.
    public static func delete(name: String, in bundle: VMBundle) throws {
        try ensureSnapshotName(name)
        let target = directory(for: bundle, name: name)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw VMError("snapshot '\(name)' does not exist")
        }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            throw VMError("could not remove \(target.path)", underlying: error)
        }
        Log.info("snapshot '\(name)' deleted")
    }

    // MARK: - Internals

    private static func ensureVMNotRunning(bundle: VMBundle) throws {
        if let pid = VMPidFile.read(bundle), VMPidFile.isAlive(pid) {
            throw VMError(
                "VM is running (PID \(pid)); stop it before taking/restoring a snapshot"
            )
        }
    }

    private static func ensureSnapshotName(_ name: String) throws {
        guard !name.isEmpty else { throw VMError("snapshot name must not be empty") }
        // Names become directory names; reject path separators + tricks.
        guard !name.contains("/"), !name.contains(".."), name != "." else {
            throw VMError("snapshot name '\(name)' contains illegal characters")
        }
    }

    private static func clone(from source: URL, to destination: URL) throws {
        let result = source.path.withCString { srcCStr in
            destination.path.withCString { dstCStr in
                Darwin.clonefile(srcCStr, dstCStr, 0)
            }
        }
        if result != 0 {
            let code = errno
            let message = String(cString: strerror(code))
            throw VMError(
                "clonefile(\(source.lastPathComponent) → \(destination.lastPathComponent)) failed: errno=\(code) (\(message))"
            )
        }
    }
}
