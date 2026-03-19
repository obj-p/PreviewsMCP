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

/// Tries registered build systems in order and returns the first match.
public enum BuildSystemDetector {
    public static func detect(for sourceFile: URL) async throws -> (any BuildSystem)? {
        // SPM first (most common for Swift-only projects)
        if let spm = try await SPMBuildSystem.detect(for: sourceFile) {
            return spm
        }
        // Future: XcodeBuildSystem, BazelBuildSystem
        return nil
    }
}

/// Errors from build system operations.
public enum BuildSystemError: Error, LocalizedError {
    case buildFailed(stderr: String, exitCode: Int32)
    case targetNotFound(sourceFile: String, project: String)
    case missingArtifacts(String)

    public var errorDescription: String? {
        switch self {
        case .buildFailed(let stderr, let exitCode):
            return "Project build failed (exit code \(exitCode)):\n\(stderr)"
        case .targetNotFound(let file, let project):
            return "Could not determine which target contains \(file) in \(project)"
        case .missingArtifacts(let msg):
            return "Build artifacts not found: \(msg)"
        }
    }
}
