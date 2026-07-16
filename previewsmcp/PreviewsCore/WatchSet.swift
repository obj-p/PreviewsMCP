import Foundation

/// Derives a session's watch set from its build context
/// (docs/state-invalidation.md stage 4): the primary file and the target's
/// sources exactly, the captured evidence's runtime inputs and definition
/// files exactly, and its source roots directory-scoped to `.swift`.
public enum WatchSet {
    /// Paths that no longer exist are dropped — `FileWatcher` refuses
    /// missing paths, and a refresh triggered by a deletion must still
    /// reinstall its watcher. They rejoin the set when a later refresh
    /// re-captures them.
    public static func derive(
        primary: String, buildContext: BuildContext?
    ) -> (paths: [String], directories: [FileWatcher.DirectoryWatch]) {
        var paths: Set<String> = [primary]
        paths.formUnion((buildContext?.sourceFiles ?? []).map(\.path))
        guard let evidence = buildContext?.evidence else {
            return (Array(paths), [])
        }
        paths.formUnion(evidence.runtimeInputs.map(\.path))
        paths.formUnion(evidence.definitionFiles.map(\.path))
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        let directories = evidence.sourceDirectories.map {
            FileWatcher.DirectoryWatch(root: $0.path, extensions: ["swift"])
        }
        return (Array(existing), directories)
    }
}
