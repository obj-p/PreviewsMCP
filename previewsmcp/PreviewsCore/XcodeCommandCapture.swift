import Foundation

/// Reads the compile command xcodebuild actually ran for a target out of the
/// build log. XCBuild logs the full swiftc invocation on a
/// `builtin-SwiftDriver -- <argv>` line (shell-escaped), the Swift source
/// list rides in the on-disk `@<...>.SwiftFileList` response file that argv
/// references, and the target's C/ObjC halves appear as `CompileC` lines. A
/// null build logs no compile lines, so successful captures are persisted
/// next to the build products, keyed on the project file and xcconfig
/// mtimes; rules_xcodeproj build-with-Bazel logs contain no SwiftDriver
/// lines at all, in which case the caller falls back to settings derivation.
enum XcodeCommandCapture {
    struct CapturedCommand: Codable {
        /// The swiftc argument vector, without the executable path.
        var arguments: [String]
        /// The target's Swift sources from the SwiftFileList response file.
        var swiftSources: [String]
    }

    private static let driverMarkers = [
        "builtin-SwiftDriver -- ", "builtin-Swift-Compilation -- ",
    ]

    /// Parse a build log for the module's compile command. Nil when the log
    /// has no matching SwiftDriver invocation (null build, or a build system
    /// that does not log one). The target's C/ObjC objects are deliberately
    /// not read from the log — an incremental build only logs CompileC for
    /// changed sources — they come from the objects directory on disk.
    static func parse(log: String, moduleName: String) -> CapturedCommand? {
        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let marker = driverMarkers.first(where: line.contains) else { continue }
            let argvText = String(line[line.range(of: marker)!.upperBound...])
            let tokens = tokenizeShellEscaped(argvText)
            guard tokens.count > 1, moduleTokenMatches(tokens, moduleName) else { continue }
            var args: [String] = []
            var swiftSources: [String] = []
            for token in tokens.dropFirst() {
                if token.hasPrefix("@"), token.hasSuffix(".SwiftFileList") {
                    swiftSources = responseFileLines(String(token.dropFirst()))
                } else {
                    args.append(token)
                }
            }
            return CapturedCommand(arguments: args, swiftSources: swiftSources)
        }
        return nil
    }

    /// True when the log came from a build system that logs SwiftDriver
    /// invocations at all — distinguishes a null build (worth forcing a
    /// recompile to capture) from build-with-Bazel projects (fall back to
    /// settings derivation immediately).
    static func logsDriverInvocations(_ log: String) -> Bool {
        driverMarkers.contains { marker in
            log.contains(marker.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Persistence

    /// A valid persisted answer: the captured command, or the knowledge that
    /// this project's build system never logs one (build-with-Bazel), which
    /// spares the per-start forced-rebuild probe.
    enum PersistedResult {
        case command(CapturedCommand)
        case driverless
    }

    private struct PersistedCapture: Codable {
        var validity: [String: Date]
        var command: CapturedCommand?
    }

    static func persist(
        _ command: CapturedCommand?, at url: URL, validity: [String: Date]
    ) {
        let persisted = PersistedCapture(validity: validity, command: command)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: url)
        }
    }

    static func loadPersisted(at url: URL, validity: [String: Date]) -> PersistedResult? {
        guard
            let data = try? Data(contentsOf: url),
            let persisted = try? JSONDecoder().decode(PersistedCapture.self, from: data),
            persisted.validity == validity
        else { return nil }
        return persisted.command.map(PersistedResult.command) ?? .driverless
    }

    /// The mtimes that must be unchanged for a persisted capture to stay
    /// valid: the project definition(s) — every referenced project's pbxproj
    /// when the marker is a workspace — and every xcconfig under the project
    /// root (X01: xcconfig contents feed the captured settings). The
    /// xcconfig walk is depth-bounded; configs live near the project.
    static func validityKeys(projectFile: URL, projectRoot: URL) -> [String: Date] {
        var keys: [String: Date] = [:]
        func record(_ url: URL) {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            {
                keys[url.path] = date
            }
        }
        if projectFile.pathExtension == "xcworkspace" {
            record(projectFile.appendingPathComponent("contents.xcworkspacedata"))
            for project in XcodeProjectMembership.projects(inWorkspace: projectFile) {
                record(project.appendingPathComponent("project.pbxproj"))
            }
        } else {
            record(projectFile.appendingPathComponent("project.pbxproj"))
        }
        let rootDepth = projectRoot.pathComponents.count
        if let enumerator = FileManager.default.enumerator(
            at: projectRoot, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) {
            for case let url as URL in enumerator {
                if url.pathComponents.count - rootDepth > 4 {
                    enumerator.skipDescendants()
                    continue
                }
                if url.pathExtension == "xcconfig" {
                    record(url)
                }
            }
        }
        return keys
    }

    // MARK: - Tokenizing

    /// Split an XCBuild-logged command line into tokens: spaces separate
    /// tokens unless backslash-escaped, and `\<char>` unescapes to `<char>`
    /// (XCBuild escapes spaces and `=` this way).
    static func tokenizeShellEscaped(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == " " {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func moduleTokenMatches(_ tokens: [String], _ moduleName: String) -> Bool {
        guard let index = tokens.firstIndex(of: "-module-name"), index + 1 < tokens.count
        else { return false }
        return tokens[index + 1] == moduleName
    }

    private static func responseFileLines(_ path: String) -> [String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }
}
