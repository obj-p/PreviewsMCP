import Foundation

/// Reads the compile command Bazel actually runs for a target out of
/// `bazel aquery 'mnemonic("SwiftCompile", <target>)' --output=jsonproto`.
/// The action's `arguments` carry the full swiftc invocation — dependency
/// module search paths, module maps, defines, and the source inputs, with
/// generated files as execroot-relative paths (B01). Bazel pre-processing
/// strips the persistent-worker prefix and the placeholder-bearing pairs
/// (`-sdk __BAZEL_XCODE_SDKROOT__` and friends are never expanded by
/// aquery); `Compiler`'s own `-target`/`-sdk` injection stays authoritative.
enum BazelCommandCapture {
    struct CapturedCommand {
        /// The swiftc argument vector after worker-prefix and placeholder
        /// stripping, still execroot-relative.
        let arguments: [String]
        /// The action's Swift source inputs, execroot-relative.
        let swiftSources: [String]
    }

    static func parse(jsonProto: String, moduleName: String) -> CapturedCommand? {
        struct ActionGraph: Decodable {
            struct Action: Decodable {
                let mnemonic: String?
                let arguments: [String]?
            }

            let actions: [Action]?
        }
        guard
            let data = jsonProto.data(using: .utf8),
            let graph = try? JSONDecoder().decode(ActionGraph.self, from: data)
        else { return nil }

        for action in graph.actions ?? [] where action.mnemonic == "SwiftCompile" {
            guard
                let arguments = action.arguments,
                let moduleIndex = arguments.firstIndex(of: "-module-name"),
                moduleIndex + 1 < arguments.count,
                arguments[moduleIndex + 1] == moduleName
            else { continue }
            let stripped = preprocess(arguments)
            return CapturedCommand(
                arguments: stripped,
                swiftSources: stripped.filter {
                    $0.hasSuffix(".swift") && !$0.hasPrefix("-")
                }
            )
        }
        return nil
    }

    /// Drop the persistent-worker/driver prefix (everything through the
    /// `swiftc` token) and the placeholder-bearing flag pairs aquery never
    /// expands.
    private static func preprocess(_ arguments: [String]) -> [String] {
        var args = arguments
        if let driverIndex = args.firstIndex(where: {
            $0 == "swiftc" || $0.hasSuffix("/swiftc")
        }) {
            args.removeSubrange(...driverIndex)
        }
        let droppedPairs: Set = ["-sdk", "-target", "-file-prefix-map"]
        var result: [String] = []
        var index = 0
        while index < args.count {
            let token = args[index]
            if droppedPairs.contains(token), index + 1 < args.count {
                index += 2
                continue
            }
            // Worker-protocol directives are consumed by rules_swift's
            // persistent worker, never by swiftc.
            if token.hasPrefix("-Xwrapped-swift") {
                index += 1
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }
}
