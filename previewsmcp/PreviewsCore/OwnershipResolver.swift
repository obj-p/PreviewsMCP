import Foundation

/// A confirmed answer to "which project owns this source file".
public struct Ownership: Sendable {
    public let kind: BuildSystemKind
    public let projectRoot: URL
    /// The confirmed target within the project, when the build system's model
    /// names one (SwiftPM target, Bazel label, Xcode target).
    public let targetName: String?
    /// The .xcodeproj/.xcworkspace that confirmed membership (Xcode only).
    public let projectFile: URL?

    public init(
        kind: BuildSystemKind,
        projectRoot: URL,
        targetName: String? = nil,
        projectFile: URL? = nil
    ) {
        self.kind = kind
        self.projectRoot = projectRoot
        self.targetName = targetName
        self.projectFile = projectFile
    }
}

/// Ownership is ternary. `indeterminate` (tool missing, manifest broken,
/// project unparseable) must never be folded into `notMember`: an
/// indeterminate nearer marker blocks farther candidates and fails the start
/// loudly, because letting a farther root win on a nearer marker's silence is
/// silent misattribution.
public enum OwnershipVerdict: Sendable {
    case confirmed(Ownership)
    case notMember(reason: String)
    case indeterminate(reason: String)
}

/// A candidate marker that did not confirm, kept for diagnostics.
public struct OwnershipDecline: Sendable {
    public let markerPath: String
    public let reason: String

    public init(markerPath: String, reason: String) {
        self.markerPath = markerPath
        self.reason = reason
    }

    var message: String {
        "\(markerPath): \(reason)"
    }
}

public enum OwnershipError: Error, LocalizedError {
    /// A nearer marker could not answer; farther candidates must not win.
    case indeterminate(OwnershipDecline, declines: [OwnershipDecline])
    /// Markers were found but none confirmed membership.
    case noOwner(sourceFile: String, declines: [OwnershipDecline])

    public var errorDescription: String? {
        switch self {
        case let .indeterminate(blocking, declines):
            var lines = [
                "Could not determine project ownership: \(blocking.message)",
            ]
            lines.append(contentsOf: declines.map { "  also considered \($0.message)" })
            return lines.joined(separator: "\n")
        case let .noOwner(sourceFile, declines):
            var lines = ["No project claims \(sourceFile):"]
            lines.append(contentsOf: declines.map { "  \($0.message)" })
            return lines.joined(separator: "\n")
        }
    }
}

/// One build system's ownership interface: find a candidate marker in a
/// directory, and confirm (or decline) membership of a file at that root.
/// Confirmation may interrogate the build system's own model but must not
/// run a native build.
protocol OwnershipResolving: Sendable {
    var kind: BuildSystemKind { get }
    func candidateMarker(in directory: URL) -> URL?
    func owner(
        of sourceFile: URL, at candidateRoot: URL, marker: URL, scheme: String?
    ) async -> OwnershipVerdict
    /// A diagnostic for a directory with no candidate marker, when the
    /// resolver can still explain why one was expected (e.g. a generator
    /// manifest whose output is missing). Nil when there is nothing to say.
    func diagnose(in directory: URL) -> OwnershipDecline?
}

extension OwnershipResolving {
    func diagnose(in _: URL) -> OwnershipDecline? {
        nil
    }
}

/// Walks upward from the source file. At each level, candidate markers are
/// consulted in tie-break order (SwiftPM, Bazel, Xcode); the nearest root
/// whose build system confirms membership wins. Returns nil only when no
/// candidate marker exists on the entire walk (standalone mode).
struct OwnershipWalk {
    let resolvers: [any OwnershipResolving]

    static let allResolvers: [any OwnershipResolving] = [
        SPMOwnershipResolver(), BazelOwnershipResolver(), XcodeOwnershipResolver(),
    ]

    static func resolvers(for kind: BuildSystemKind) -> [any OwnershipResolving] {
        allResolvers.filter { $0.kind == kind }
    }

    func resolve(sourceFile: URL, scheme: String?) async throws -> Ownership? {
        var declines: [OwnershipDecline] = []
        var dir = sourceFile.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: "/")

        while dir.path != root.path {
            // An indeterminate marker blocks FARTHER levels, not same-level
            // peers: a peer at the same distance that positively confirms is
            // not a guess, so the throw is deferred until the level ends.
            var blocking: OwnershipDecline?
            for resolver in resolvers {
                guard let marker = resolver.candidateMarker(in: dir) else {
                    if let diagnostic = resolver.diagnose(in: dir) {
                        declines.append(diagnostic)
                    }
                    continue
                }
                switch await resolver.owner(
                    of: sourceFile, at: dir, marker: marker, scheme: scheme
                ) {
                case let .confirmed(ownership):
                    return ownership
                case let .notMember(reason):
                    declines.append(
                        OwnershipDecline(markerPath: marker.path, reason: reason)
                    )
                case let .indeterminate(reason):
                    let decline = OwnershipDecline(markerPath: marker.path, reason: reason)
                    if blocking == nil {
                        blocking = decline
                    } else {
                        declines.append(decline)
                    }
                }
            }
            if let blocking {
                throw OwnershipError.indeterminate(blocking, declines: declines)
            }
            dir = dir.deletingLastPathComponent()
        }

        guard declines.isEmpty else {
            throw OwnershipError.noOwner(
                sourceFile: sourceFile.lastPathComponent, declines: declines
            )
        }
        return nil
    }
}

// MARK: - Per-system resolvers

struct SPMOwnershipResolver: OwnershipResolving {
    let kind = BuildSystemKind.spm

    func candidateMarker(in directory: URL) -> URL? {
        SPMBuildSystem.packageMarker(in: directory)
    }

    func owner(
        of sourceFile: URL, at candidateRoot: URL, marker _: URL, scheme _: String?
    ) async -> OwnershipVerdict {
        await SPMBuildSystem.confirmOwnership(
            projectRoot: candidateRoot, sourceFile: sourceFile
        )
    }
}

struct BazelOwnershipResolver: OwnershipResolving {
    let kind = BuildSystemKind.bazel

    func candidateMarker(in directory: URL) -> URL? {
        BazelBuildSystem.projectMarker(in: directory)
    }

    func owner(
        of sourceFile: URL, at candidateRoot: URL, marker _: URL, scheme _: String?
    ) async -> OwnershipVerdict {
        await BazelBuildSystem.confirmOwnership(
            projectRoot: candidateRoot, sourceFile: sourceFile
        )
    }
}

struct XcodeOwnershipResolver: OwnershipResolving {
    let kind = BuildSystemKind.xcode

    func candidateMarker(in directory: URL) -> URL? {
        XcodeBuildSystem.findXcodeProject(in: directory)
    }

    func owner(
        of sourceFile: URL, at candidateRoot: URL, marker: URL, scheme: String?
    ) async -> OwnershipVerdict {
        await XcodeBuildSystem.confirmOwnership(
            projectRoot: candidateRoot, projectFile: marker,
            sourceFile: sourceFile, scheme: scheme
        )
    }

    /// An XcodeGen manifest with no generated .xcodeproj is not a candidate
    /// marker, but naming it turns "no project found" into an actionable
    /// diagnosis.
    func diagnose(in directory: URL) -> OwnershipDecline? {
        guard let manifest = XcodeBuildSystem.generatedProjectManifest(in: directory) else {
            return nil
        }
        return OwnershipDecline(
            markerPath: manifest.path,
            reason: "XcodeGen manifest present but no generated .xcodeproj; run `xcodegen generate`"
        )
    }
}
