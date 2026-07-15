import Foundation

/// Protocol for build system integrations. Ownership of a source file is
/// resolved by `OwnershipWalk` before an implementation is constructed; each
/// implementation builds the project and provides compiler flags (and
/// optionally .o files) for preview compilation.
public protocol BuildSystem: Sendable {
    /// Build the project and return the context needed to compile the preview dylib.
    func build(platform: PreviewPlatform) async throws -> BuildContext

    /// The project root directory.
    var projectRoot: URL { get }
}

/// Explicitly selects a build system, bypassing marker-order auto-detection.
public enum BuildSystemKind: String, Sendable, CaseIterable {
    case spm
    case bazel
    case xcode
}

/// Tries registered build systems in order and returns the first match.
public enum BuildSystemDetector {
    /// Detect the build system for a source file.
    /// - Parameters:
    ///   - sourceFile: The Swift source file to detect the build system for.
    ///   - projectRoot: If provided, use this as the project root instead of auto-detecting.
    ///   - scheme: Optional Xcode scheme name. Only used when the detected build
    ///     system is `XcodeBuildSystem`; ignored for SPM and Bazel.
    ///   - buildSystem: Optional explicit override. When set, the marker order is
    ///     skipped and the requested system is constructed directly. An override
    ///     always wins over auto-detection.
    public static func detect(
        for sourceFile: URL,
        projectRoot: URL? = nil,
        scheme: String? = nil,
        buildSystem: BuildSystemKind? = nil
    ) async throws -> (any BuildSystem)? {
        // An explicit override wins over auto-detection and never falls through
        // to the other systems.
        if let buildSystem {
            return try await forced(
                buildSystem, for: sourceFile, projectRoot: projectRoot, scheme: scheme
            )
        }
        // If an explicit project root is provided, detect which build system applies there
        if let projectRoot {
            if SPMBuildSystem.packageMarker(in: projectRoot) != nil {
                return SPMBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
            }
            if BazelBuildSystem.projectMarker(in: projectRoot) != nil {
                return BazelBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
            }
            // Xcode: enumerate directory for *.xcworkspace / *.xcodeproj (name varies)
            if let projectFile = XcodeBuildSystem.findXcodeProject(in: projectRoot) {
                return XcodeBuildSystem(
                    projectRoot: projectRoot,
                    sourceFile: sourceFile,
                    projectFile: projectFile,
                    requestedScheme: scheme
                )
            }
            return nil
        }
        // Nearest-confirming-root walk: at each directory level the candidate
        // markers are consulted in tie-break order (SwiftPM, Bazel, Xcode) and
        // the nearest root whose own model confirms membership wins. Markers
        // found but never confirmed fail loudly with their reasons; nil means
        // no markers exist at all (standalone mode).
        return try await resolve(
            walk: OwnershipWalk(resolvers: OwnershipWalk.allResolvers),
            sourceFile: sourceFile, scheme: scheme
        )
    }

    /// Build the requested system for an explicit override. With a `projectRoot`
    /// it constructs the system directly; without one it walks up from the
    /// source file consulting only that system's markers, still requiring
    /// membership confirmation. Either way it never falls through to another
    /// build system.
    private static func forced(
        _ kind: BuildSystemKind,
        for sourceFile: URL,
        projectRoot: URL?,
        scheme: String?
    ) async throws -> (any BuildSystem)? {
        guard let projectRoot else {
            return try await resolve(
                walk: OwnershipWalk(resolvers: OwnershipWalk.resolvers(for: kind)),
                sourceFile: sourceFile, scheme: scheme
            )
        }
        switch kind {
        case .spm:
            return SPMBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
        case .bazel:
            return BazelBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
        case .xcode:
            guard let projectFile = XcodeBuildSystem.findXcodeProject(in: projectRoot) else {
                throw BuildSystemError.buildSystemUnavailable(
                    kind: kind.rawValue,
                    reason: "no .xcodeproj or .xcworkspace found in \(projectRoot.path)"
                )
            }
            return XcodeBuildSystem(
                projectRoot: projectRoot,
                sourceFile: sourceFile,
                projectFile: projectFile,
                requestedScheme: scheme
            )
        }
    }

    private static func resolve(
        walk: OwnershipWalk, sourceFile: URL, scheme: String?
    ) async throws -> (any BuildSystem)? {
        let standardized = sourceFile.standardizedFileURL
        guard let ownership = try await walk.resolve(sourceFile: standardized, scheme: scheme)
        else { return nil }
        switch ownership.kind {
        case .spm:
            let system = SPMBuildSystem(
                projectRoot: ownership.projectRoot, sourceFile: standardized
            )
            if let targetName = ownership.targetName {
                await system.prime(targetName: targetName)
            }
            return system
        case .bazel:
            return BazelBuildSystem(
                projectRoot: ownership.projectRoot, sourceFile: standardized,
                confirmedTarget: ownership.targetName
            )
        case .xcode:
            guard
                let projectFile = ownership.projectFile
                ?? XcodeBuildSystem.findXcodeProject(in: ownership.projectRoot)
            else { return nil }
            return XcodeBuildSystem(
                projectRoot: ownership.projectRoot,
                sourceFile: standardized,
                projectFile: projectFile,
                requestedScheme: scheme,
                confirmedTarget: ownership.targetName
            )
        }
    }
}

/// Errors from build system operations.
public enum BuildSystemError: Error, LocalizedError {
    case buildFailed(stderr: String, exitCode: Int32)
    case targetNotFound(sourceFile: String, project: String)
    case missingArtifacts(String)
    case ambiguousTarget(sourceFile: String, candidates: [String])
    case unknownScheme(requested: String, candidates: [String])
    case buildSystemUnavailable(kind: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .buildFailed(stderr, exitCode):
            "Project build failed (exit code \(exitCode)):\n\(stderr)"
        case let .targetNotFound(file, project):
            "Could not determine which target contains \(file) in \(project)"
        case let .missingArtifacts(msg):
            "Build artifacts not found: \(msg)"
        case let .ambiguousTarget(file, candidates):
            "Multiple schemes found for \(file) and none matched the source file's directory. Pass the `scheme` parameter to pick one. Available schemes: \(candidates.joined(separator: ", "))"
        case let .unknownScheme(requested, candidates):
            "Scheme '\(requested)' not found in project. Available schemes: \(candidates.joined(separator: ", "))"
        case let .buildSystemUnavailable(kind, reason):
            "Requested build system '\(kind)' is unavailable: \(reason)"
        }
    }
}
