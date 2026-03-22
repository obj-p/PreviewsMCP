import Foundation

/// Result of a successful preview compilation.
public struct CompileResult: Sendable {
    public let dylibPath: URL
    public let literals: [LiteralEntry]
}

/// Orchestrates the full preview pipeline: parse → generate bridge → compile → return dylib path.
public actor PreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public nonisolated let previewIndex: Int

    private let compiler: Compiler
    private let platform: PreviewPlatform
    private let buildContext: BuildContext?
    private var traits: PreviewTraits
    private var compilationResult: CompilationResult?
    private var lastOriginalSource: String?
    private var lastLiterals: [LiteralEntry]?

    public enum State: Sendable {
        case idle
        case compiling
        case compiled(URL)
        case error(String)
    }

    public private(set) var state: State = .idle

    public var currentTraits: PreviewTraits { traits }

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        compiler: Compiler,
        platform: PreviewPlatform = .macOS,
        buildContext: BuildContext? = nil,
        traits: PreviewTraits = PreviewTraits()
    ) {
        self.id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.compiler = compiler
        self.platform = platform
        self.buildContext = buildContext
        self.traits = traits
    }

    /// Run the full pipeline and return the compiled dylib path + literal map.
    public func compile() async throws -> CompileResult {
        state = .compiling

        do {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let previews = PreviewParser.parse(source: source)

            guard previewIndex < previews.count else {
                throw PreviewSessionError.previewNotFound(
                    index: previewIndex,
                    available: previews.count
                )
            }
            let preview = previews[previewIndex]

            let compiledSource: String
            let literals: [LiteralEntry]
            let moduleName: String
            let extraFlags: [String]
            let additionalSourceFiles: [URL]

            if let ctx = buildContext {
                if ctx.supportsTier2, let srcFiles = ctx.sourceFiles {
                    // Tier 2: compile preview file (with thunks) + all other target sources
                    let result = BridgeGenerator.generateOverlaySource(
                        originalSource: source,
                        closureBody: preview.closureBody,
                        platform: platform,
                        traits: traits
                    )
                    compiledSource = result.source
                    literals = result.literals
                    additionalSourceFiles = srcFiles
                    moduleName = ctx.moduleName
                } else {
                    // Tier 1: bridge-only (no literal hot-reload)
                    // Use a different module name for the bridge dylib to avoid
                    // "file is part of module X; ignoring import" when swiftc sees
                    // both -module-name X and @testable import X in the same file.
                    compiledSource = BridgeGenerator.generateBridgeOnlySource(
                        moduleName: ctx.moduleName,
                        closureBody: preview.closureBody,
                        platform: platform,
                        traits: traits
                    )
                    literals = []
                    additionalSourceFiles = []
                    moduleName = "PreviewBridge_\(ctx.moduleName)"
                }
                extraFlags = ctx.compilerFlags
            } else {
                // Standalone mode: existing behavior
                let result = BridgeGenerator.generateCombinedSource(
                    originalSource: source,
                    closureBody: preview.closureBody,
                    platform: platform,
                    traits: traits
                )
                compiledSource = result.source
                literals = result.literals
                moduleName = Self.moduleName(for: sourceFile)
                extraFlags = []
                additionalSourceFiles = []
            }

            let compileResult = try await compiler.compileCombined(
                source: compiledSource,
                moduleName: moduleName,
                extraFlags: extraFlags,
                additionalSourceFiles: additionalSourceFiles
            )

            compilationResult = compileResult
            lastOriginalSource = source
            lastLiterals = literals
            state = .compiled(compileResult.dylibPath)

            return CompileResult(dylibPath: compileResult.dylibPath, literals: literals)
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Attempt a fast literal-only update. Returns changed literal IDs and new values,
    /// or nil if a structural recompile is needed.
    /// Returns nil for Tier 1 project mode (bridge-only, no thunks).
    public func tryLiteralUpdate(newSource: String) -> [(id: String, newValue: LiteralValue)]? {
        // Tier 1 bridge-only has no DesignTimeStore thunks
        if let ctx = buildContext, !ctx.supportsTier2 { return nil }
        guard let oldSource = lastOriginalSource else { return nil }

        switch LiteralDiffer.diff(old: oldSource, new: newSource) {
        case .literalOnly(let changes):
            lastOriginalSource = newSource
            return changes
        case .structural:
            return nil
        }
    }

    /// Update traits and recompile. Returns the new dylib. @State is lost.
    public func reconfigure(traits: PreviewTraits) async throws -> CompileResult {
        self.traits = self.traits.merged(with: traits)
        return try await compile()
    }

    private static func moduleName(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let hash = String(abs(file.path.hashValue), radix: 16).prefix(6)
        return "Preview_\(stem)_\(hash)"
    }
}

public enum PreviewSessionError: Error, LocalizedError, CustomStringConvertible {
    case previewNotFound(index: Int, available: Int)

    public var description: String {
        switch self {
        case .previewNotFound(let index, let available):
            return "Preview index \(index) not found. File has \(available) preview(s)."
        }
    }

    public var errorDescription: String? { description }
}
