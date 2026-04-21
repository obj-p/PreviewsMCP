import Foundation

/// Wrapper around `swift build` that auto-recovers from llbuild's
/// "command X not registered" errors by cleaning the affected
/// `.build/<triple>/` and retrying once.
///
/// SPM's incremental-build state (the llbuild `build.db`) can become
/// inconsistent with the regenerated build description across separate
/// `swift` invocations — particularly when the same package is built for
/// multiple triples in different processes. The error surfaces as:
///
///     error: command <path>/.build/<triple>/<config>/swift-version--XXX.txt not registered
///     error: failed to write auxiliary file: command <same path> not registered
///
/// The fix recommended by SPM maintainers is to clear the `<triple>` build
/// directory; this helper detects the error pattern in stderr, parses the
/// affected directory from the message, removes it, and retries once.
public enum SPMBuildRecovery {

    /// Run `swift build` with the given arguments. On llbuild
    /// "not registered" failures, clean the affected `.build/<triple>/`
    /// directory and retry once.
    ///
    /// - Parameters:
    ///   - arguments: Arguments to pass to `swift` (e.g. `["build", "--triple", "..."]`).
    ///     Do NOT prefix with `swift` — the helper invokes `/usr/bin/env swift`.
    ///   - workingDirectory: Working directory (the SPM package root).
    /// - Returns: The successful `ProcessOutput`.
    /// - Throws: The underlying error if the retry also fails, or any
    ///   non-recoverable failure on the first attempt.
    @discardableResult
    public static func runSwift(
        arguments: [String], workingDirectory: URL?
    ) async throws -> ProcessOutput {
        let result = try await runAsync(
            "/usr/bin/env",
            arguments: ["swift"] + arguments,
            workingDirectory: workingDirectory
        )
        if result.exitCode == 0 { return result }

        // Look for the "not registered" pattern in stderr.
        guard let tripleDir = parseStaleTripleDirectory(stderr: result.stderr) else {
            return result
        }

        cleanStaleArtifacts(tripleDir: tripleDir)

        return try await runAsync(
            "/usr/bin/env",
            arguments: ["swift"] + arguments,
            workingDirectory: workingDirectory
        )
    }

    /// Remove the two artifacts that hold the inconsistent llbuild state:
    ///
    ///   1. The per-triple build directory whose state SPM is stuck on.
    ///   2. The shared `.build/build.db` (llbuild's task database). It
    ///      lives ONE level above the triple directory and aggregates
    ///      command registrations across triples, so a stale entry
    ///      registered for one triple can corrupt builds at another.
    ///      Without removing it, the retry hits the same error.
    ///
    /// Best-effort: if removal fails (e.g. permissions), the caller's retry
    /// will surface the original error.
    static func cleanStaleArtifacts(tripleDir: URL) {
        try? FileManager.default.removeItem(at: tripleDir)
        let buildDB = tripleDir.deletingLastPathComponent().appendingPathComponent("build.db")
        try? FileManager.default.removeItem(at: buildDB)
    }

    /// Parse the affected `<...>.build/<triple>/` directory from an SPM
    /// "not registered" error message. Returns nil if the message doesn't
    /// match the known pattern OR if the resolved directory doesn't look
    /// like an Apple/Linux target triple.
    ///
    /// The triple-shape guard matters: cleanup also nukes `.build/build.db`,
    /// so we must be confident the resolved directory really is a per-triple
    /// build dir. Without the guard, an SPM error mentioning a non-triple
    /// path under `.build/` (e.g. a workspace-level artifact) would cause us
    /// to delete the wrong directory plus the shared database.
    ///
    /// Example input line:
    ///     error: command /pkg/.build/arm64-apple-ios-simulator/debug/swift-version--ABC.txt not registered
    /// Returns:
    ///     file:///pkg/.build/arm64-apple-ios-simulator/
    static func parseStaleTripleDirectory(stderr: String) -> URL? {
        for line in stderr.split(separator: "\n") {
            guard line.contains("not registered") else { continue }
            // Extract the path between "command " and " not registered".
            guard let cmdRange = line.range(of: "command "),
                let endRange = line.range(
                    of: " not registered", range: cmdRange.upperBound..<line.endIndex)
            else { continue }
            let pathSubstring = line[cmdRange.upperBound..<endRange.lowerBound]
            let path = String(pathSubstring).trimmingCharacters(in: .whitespaces)
            guard path.hasPrefix("/") else { continue }
            // Walk up from the offending file until the parent's
            // lastPathComponent is ".build" — that's the <triple> directory.
            var url = URL(fileURLWithPath: path).standardizedFileURL
            while url.path != "/" {
                let parent = url.deletingLastPathComponent()
                if parent.lastPathComponent == ".build" {
                    return looksLikeTriple(url.lastPathComponent) ? url : nil
                }
                url = parent
            }
        }
        return nil
    }

    /// Whether a directory name looks like a SPM/Apple/Linux target triple,
    /// e.g. `arm64-apple-macosx`, `arm64-apple-ios-simulator`,
    /// `x86_64-unknown-linux-gnu`. Triples are 3+ hyphen-separated tokens
    /// of `[a-z0-9_]`. The 3-token floor rejects SPM internal directories
    /// like `workspace-state`, `manifests-cache`, etc. that share `.build/`
    /// with the per-triple build dirs.
    static func looksLikeTriple(_ name: String) -> Bool {
        let tokens = name.split(separator: "-", omittingEmptySubsequences: false)
        guard tokens.count >= 3 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        return tokens.allSatisfy { token in
            !token.isEmpty && token.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}
