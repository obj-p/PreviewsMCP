import Foundation

/// Reads the compile command `swift build` actually ran for a target out of
/// SPM's llbuild manifest (`<scratch>/<config>.yaml`). The manifest encodes
/// each module's compile as a `"C.<Target>-<triple>-<config>.module"` node
/// whose `args:` is the full swiftc argument vector and whose `inputs:` are
/// the exact compile inputs — exclusions already applied, generated and
/// plugin-produced sources already included. Both lines are JSON arrays on a
/// single line, so the node is recovered with a line scan plus JSON decode,
/// no YAML parser.
enum SPMCommandCapture {
    struct CapturedCommand {
        /// The swiftc argument vector, without the executable path.
        let arguments: [String]
        /// The target's Swift compile inputs (non-Swift manifest inputs like
        /// object files and virtual nodes filtered out).
        let swiftInputs: [URL]
    }

    static func capture(manifestAt url: URL, forTarget target: String) throws -> CapturedCommand {
        guard
            let data = try? Data(contentsOf: url),
            let contents = String(data: data, encoding: .utf8)
        else {
            throw BuildSystemError.missingArtifacts(
                "Could not read the build manifest at \(url.path)"
            )
        }

        let moduleNeedle = "\"-module-name\",\"\(target)\""
        var inCompileNode = false
        var inputsLine: String?
        var matchedArgsLine: String?
        var candidates: [CapturedCommand] = []

        func closeNode() {
            defer {
                inputsLine = nil
                matchedArgsLine = nil
            }
            guard let matchedArgsLine else { return }
            let args = decodeStringArray(from: matchedArgsLine, prefix: "args: ")
            guard args.count > 1 else { return }
            let inputs = inputsLine.map {
                decodeStringArray(from: $0, prefix: "inputs: ")
                    .filter { $0.hasSuffix(".swift") }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
            } ?? []
            candidates.append(
                CapturedCommand(arguments: Array(args.dropFirst()), swiftInputs: inputs)
            )
        }

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if rawLine.hasPrefix("  \"") {
                closeNode()
                inCompileNode = rawLine.hasPrefix("  \"C.")
                continue
            }
            guard inCompileNode else { continue }
            if line.hasPrefix("inputs: ") {
                inputsLine = line
            } else if line.hasPrefix("args: "), line.contains(moduleNeedle) {
                matchedArgsLine = line
            }
        }
        closeNode()

        // SPM can emit more than one compile node per module (a wrapper or
        // emit-module invocation plus the real one); the real compile carries
        // -c. Falling back to any candidate keeps unusual manifests working.
        guard
            let command = candidates.first(where: { $0.arguments.contains("-c") })
            ?? candidates.first
        else {
            throw BuildSystemError.missingArtifacts(
                "No compile command for target '\(target)' in the build manifest at \(url.path)"
            )
        }
        return command
    }

    private static func decodeStringArray(from line: String, prefix: String) -> [String] {
        let json = line.dropFirst(prefix.count)
        guard
            let data = json.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
    }
}
