import Foundation

/// Turns a compile command captured from a native build into flags a Tier 2
/// preview compile can reuse. The philosophy is capture fidelity: only
/// known build-bookkeeping is stripped (inputs, outputs, output-file maps,
/// incremental and diagnostics state, module caches, and the module/target
/// identity the preview compile sets itself); every other flag — defines,
/// language modes, feature flags, bridging headers, plugin loads, search
/// paths, unsafe flags — passes through untouched, so fidelity does not
/// depend on an ever-growing allowlist.
enum CompileCommandNormalizer {
    static func normalize(_ args: [String]) -> [String] {
        var result: [String] = []
        var index = args.startIndex
        while index < args.count {
            let token = args[index]
            if let valueCount = droppedFlags[token] {
                index += 1 + valueCount
                continue
            }
            if token.hasPrefix("@") || jobCountPattern(token) {
                index += 1
                continue
            }
            if token == "-Xfrontend", index + 1 < args.count,
               droppedFrontendFlags.contains(args[index + 1])
            {
                index += 2
                continue
            }
            if token.hasSuffix(".swift"), !token.hasPrefix("-") {
                index += 1
                continue
            }
            result.append(token)
            index += 1
        }
        return result
    }

    /// Bookkeeping flags to drop, with the number of value tokens each
    /// consumes. `-target`/`-sdk` pass through: the captured values are
    /// appended after `Compiler`'s own injection, so the native build's pair
    /// wins (the design's SwiftPM/Xcode ruling); per-system pre-processors
    /// drop placeholder-bearing captures (Bazel) before reaching here.
    private static let droppedFlags: [String: Int] = [
        "-emit-dependencies": 0,
        "-emit-module": 0,
        "-incremental": 0,
        "-c": 0,
        "-enable-batch-mode": 0,
        "-serialize-diagnostics": 0,
        "-parseable-output": 0,
        "-parse-as-library": 0,
        "-emit-objc-header": 0,
        "-whole-module-optimization": 0,
        "-emit-module-path": 1,
        "-output-file-map": 1,
        "-index-store-path": 1,
        "-index-unit-output-path": 1,
        "-module-cache-path": 1,
        "-emit-objc-header-path": 1,
        "-module-name": 1,
        "-o": 1,
    ]

    private static let droppedFrontendFlags: Set<String> = [
        "-serialize-debugging-options",
    ]

    private static func jobCountPattern(_ token: String) -> Bool {
        token.hasPrefix("-j") && token.dropFirst(2).allSatisfy(\.isNumber)
            && token.count > 2
    }
}
