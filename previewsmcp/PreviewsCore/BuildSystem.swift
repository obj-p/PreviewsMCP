import Foundation

/// Protocol for build system integrations. Each implementation detects its project type,
/// builds the project, and provides compiler flags (and optionally .o files) for preview compilation.
public protocol BuildSystem: Sendable {
    /// Check if this build system applies to the given source file.
    /// Returns a configured instance ready to build, or nil if this build system doesn't apply.
    static func detect(for sourceFile: URL) async throws -> Self?

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
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(
                atPath: projectRoot.appendingPathComponent("Package.swift").path,
                isDirectory: &isDir
            ), !isDir.boolValue {
                return SPMBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
            }
            for marker in BazelBuildSystem.projectMarkers {
                isDir = false
                if fm.fileExists(
                    atPath: projectRoot.appendingPathComponent(marker).path,
                    isDirectory: &isDir
                ), !isDir.boolValue {
                    return BazelBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
                }
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
        // SPM first (most common for Swift-only projects)
        if let spm = try await SPMBuildSystem.detect(for: sourceFile) {
            return spm
        }
        // Bazel (rules_swift projects)
        if let bazel = try await BazelBuildSystem.detect(for: sourceFile) {
            return bazel
        }
        // Xcode (.xcworkspace / .xcodeproj)
        if let xcode = try await XcodeBuildSystem.detect(for: sourceFile, scheme: scheme) {
            return xcode
        }
        return nil
    }

    /// Build the requested system for an explicit override. With a `projectRoot`
    /// it constructs the system directly; without one it walks up from the source
    /// file via that system's own `detect`. Either way it never falls through to
    /// another build system.
    private static func forced(
        _ kind: BuildSystemKind,
        for sourceFile: URL,
        projectRoot: URL?,
        scheme: String?
    ) async throws -> (any BuildSystem)? {
        switch kind {
        case .spm:
            guard let projectRoot else {
                return try await SPMBuildSystem.detect(for: sourceFile)
            }
            return SPMBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
        case .bazel:
            guard let projectRoot else {
                return try await BazelBuildSystem.detect(for: sourceFile)
            }
            return BazelBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
        case .xcode:
            guard let projectRoot else {
                return try await XcodeBuildSystem.detect(for: sourceFile, scheme: scheme)
            }
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
