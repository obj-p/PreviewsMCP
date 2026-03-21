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
    /// Detect the build system for a source file.
    /// - Parameters:
    ///   - sourceFile: The Swift source file to detect the build system for.
    ///   - projectRoot: If provided, use this as the project root instead of auto-detecting.
    public static func detect(for sourceFile: URL, projectRoot: URL? = nil) async throws -> (any BuildSystem)? {
        // If an explicit project root is provided, detect which build system applies there
        if let projectRoot = projectRoot {
            let fm = FileManager.default
            var isDir: ObjCBool = false
            if fm.fileExists(
                atPath: projectRoot.appendingPathComponent("Package.swift").path,
                isDirectory: &isDir), !isDir.boolValue
            {
                return SPMBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
            }
            for marker in BazelBuildSystem.projectMarkers {
                isDir = false
                if fm.fileExists(
                    atPath: projectRoot.appendingPathComponent(marker).path,
                    isDirectory: &isDir), !isDir.boolValue
                {
                    return BazelBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
                }
            }
            // Xcode: enumerate directory for *.xcworkspace / *.xcodeproj (name varies)
            if let projectFile = XcodeBuildSystem.findXcodeProject(in: projectRoot) {
                return XcodeBuildSystem(
                    projectRoot: projectRoot, sourceFile: sourceFile, projectFile: projectFile)
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
        if let xcode = try await XcodeBuildSystem.detect(for: sourceFile) {
            return xcode
        }
        return nil
    }
}

/// Errors from build system operations.
public enum BuildSystemError: Error, LocalizedError {
    case buildFailed(stderr: String, exitCode: Int32)
    case targetNotFound(sourceFile: String, project: String)
    case missingArtifacts(String)
    case ambiguousTarget(sourceFile: String, candidates: [String])

    public var errorDescription: String? {
        switch self {
        case .buildFailed(let stderr, let exitCode):
            return "Project build failed (exit code \(exitCode)):\n\(stderr)"
        case .targetNotFound(let file, let project):
            return "Could not determine which target contains \(file) in \(project)"
        case .missingArtifacts(let msg):
            return "Build artifacts not found: \(msg)"
        case .ambiguousTarget(let file, let candidates):
            return
                "Multiple schemes found for \(file). Use projectRoot to disambiguate. Available schemes: \(candidates.joined(separator: ", "))"
        }
    }
}
