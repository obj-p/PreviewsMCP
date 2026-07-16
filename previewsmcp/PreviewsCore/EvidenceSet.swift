import Foundation

/// The filesystem inputs a session's compile context was derived from
/// (docs/state-invalidation.md stage 3). Carried on `BuildContext` and
/// logged at session start; stage 4 turns it into the watch set whose
/// changes re-run the producer. Enumeration is best-effort per build
/// system — a missing category degrades to today's behavior (not
/// watched), never to a wrong watch.
public struct EvidenceSet: Sendable {
    /// Source roots of the target and its local dependencies. Directory
    /// scope is what makes file addition/removal visible; dependency
    /// source files need no category of their own — an edit under a
    /// dependency's root fires the directory match.
    public let sourceDirectories: [URL]

    /// Resource files staged into the preview's runtime bundle (SwiftPM
    /// `copy-tool` node inputs; scoped out for Xcode and Bazel).
    public let runtimeInputs: [URL]

    /// Project-definition files: the package manifest and pin file, the
    /// referenced pbxprojs and xcconfigs, the XcodeGen manifest, the
    /// Bazel module and package build files.
    public let definitionFiles: [URL]

    public init(
        sourceDirectories: [URL] = [],
        runtimeInputs: [URL] = [],
        definitionFiles: [URL] = []
    ) {
        self.sourceDirectories = sourceDirectories
        self.runtimeInputs = runtimeInputs
        self.definitionFiles = definitionFiles
    }

    public var isEmpty: Bool {
        sourceDirectories.isEmpty && runtimeInputs.isEmpty && definitionFiles.isEmpty
    }

    /// One-line summary for the session-start log.
    public var logDescription: String {
        "evidence: \(sourceDirectories.count) source dir(s), "
            + "\(runtimeInputs.count) runtime input(s), "
            + "\(definitionFiles.count) definition file(s)"
    }

    /// Assemble a sorted set, nil when nothing was enumerated. The shared
    /// tail of every build system's derivation.
    public static func make(
        sourceDirectories: some Sequence<URL>,
        runtimeInputs: some Sequence<URL> = [],
        definitionFiles: some Sequence<URL> = []
    ) -> EvidenceSet? {
        let set = EvidenceSet(
            sourceDirectories: sourceDirectories.sorted { $0.path < $1.path },
            runtimeInputs: runtimeInputs.sorted { $0.path < $1.path },
            definitionFiles: definitionFiles.sorted { $0.path < $1.path }
        )
        return set.isEmpty ? nil : set
    }
}

/// Product-vs-evidence classification (docs/state-invalidation.md,
/// exclusion rule). Every captured path is realpath-canonicalized — via
/// the same `FileWatcher.canonicalPath` the stage-4 watcher uses for
/// fired FSEvents paths, so producer and consumer of the watch set can
/// never disagree on identity. Realpath is load-bearing for Bazel, where
/// aquery spells a `path_override` local dependency's sources as
/// `external/…` paths that resolve back into the workspace, while
/// fetched dependencies resolve into the output base.
///
/// Product exclusion is prefix-based against the product roots each
/// build system actually uses (its scratch dir, output base, or
/// DerivedData paths) — never name-convention fragments, which both
/// miss relocated build dirs (`--scratch-path`, `--output_base`) and
/// falsely exclude user paths that merely contain a marker-like name.
public enum EvidenceClassifier {
    /// Canonicalize `url` and answer whether it is watchable evidence.
    /// Returns nil for missing paths and for paths under any product
    /// root.
    public static func evidencePath(_ url: URL, productRoots: [URL]) -> URL? {
        guard let canonical = FileWatcher.canonicalPath(url.path) else { return nil }
        for root in productRoots {
            if canonical == root.path || canonical.hasPrefix(root.path + "/") {
                return nil
            }
        }
        return URL(fileURLWithPath: canonical)
    }

    /// Canonicalize a product root itself (so prefix comparison happens
    /// realpath-to-realpath). A root that does not exist yet resolves
    /// as-is.
    public static func productRoot(_ url: URL) -> URL {
        if let canonical = FileWatcher.canonicalPath(url.path) {
            return URL(fileURLWithPath: canonical, isDirectory: true)
        }
        return url.standardizedFileURL
    }

    /// Source roots for groups of compile inputs: per group, classify
    /// each path, take the survivors' common ancestor, and accept it
    /// only when no product root lives beneath it — a root containing a
    /// build-product directory is the watch firehose the design's
    /// stream-root hygiene forbids. A rejected or unresolvable common
    /// ancestor degrades to the survivors' parent directories, filtered
    /// by the same rule; a source sitting directly in a
    /// product-containing directory (a `path: "."` target root) yields
    /// no root and keeps today's unwatched behavior, per the design's
    /// named limitation.
    public static func sourceRoots(
        forGroups groups: [[URL]], productRoots: [URL]
    ) -> Set<URL> {
        func containsProduct(_ dir: URL) -> Bool {
            productRoots.contains {
                $0.path == dir.path || $0.path.hasPrefix(dir.path + "/")
            }
        }

        var roots: Set<URL> = []
        for group in groups {
            let survivors = group.compactMap { evidencePath($0, productRoots: productRoots) }
            guard !survivors.isEmpty else { continue }
            if let common = commonDirectory(of: survivors), !containsProduct(common) {
                roots.insert(common)
            } else {
                for survivor in survivors {
                    let parent = survivor.deletingLastPathComponent()
                    if !containsProduct(parent) {
                        roots.insert(parent)
                    }
                }
            }
        }
        return roots
    }

    /// The deepest directory containing every given file (their common
    /// ancestor). For a SwiftPM target's sources this is the target's
    /// source directory. Nil when the files share no ancestor below the
    /// filesystem root.
    public static func commonDirectory(of files: [URL]) -> URL? {
        guard var common = files.first?.deletingLastPathComponent().pathComponents else {
            return nil
        }
        for file in files.dropFirst() {
            let components = file.deletingLastPathComponent().pathComponents
            var shared = 0
            while shared < min(common.count, components.count),
                  common[shared] == components[shared]
            {
                shared += 1
            }
            common = Array(common.prefix(shared))
        }
        guard common.count > 1 else { return nil }
        return URL(fileURLWithPath: common.joined(separator: "/").replacingOccurrences(
            of: "//", with: "/"
        ), isDirectory: true)
    }
}
