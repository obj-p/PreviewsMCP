import Foundation

/// Result of a successful preview compilation.
public struct CompileResult: Sendable {
    public let dylibPath: URL
    public let literals: [LiteralEntry]
}

/// Result of compiling a preview for the JIT structural-reload path: a `.o` whose
/// `entrySymbol` renders the preview to a PNG at `imagePath` when run in the agent.
/// The render entry seeds `DesignTimeStore` from `valuesPath` (JSON) first, so a
/// literal-only edit can rewrite that file and re-render the same `.o` without
/// recompiling. `literals` are the design-time values baked at compile time.
public struct JITRenderBuild: Sendable {
    public let objectPath: URL
    public let imagePath: URL
    public let valuesPath: URL
    public let entrySymbol: String
    public let literals: [LiteralEntry]
}

/// Orchestrates the full preview pipeline: parse → generate bridge → compile → return dylib path.
public actor PreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public private(set) var previewIndex: Int

    private let compiler: Compiler
    private let platform: PreviewPlatform
    private let buildContext: BuildContext?
    private var traits: PreviewTraits
    private let setupModule: String?
    private let setupType: String?
    private let setupCompilerFlags: [String]
    private let setupSDKPath: String?
    private var compilationResult: CompilationResult?
    private var lastOriginalSource: String?
    private var lastLiterals: [LiteralEntry]?
    private var lastJITBuild: JITRenderBuild?

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
        traits: PreviewTraits = PreviewTraits(),
        setupModule: String? = nil,
        setupType: String? = nil,
        setupCompilerFlags: [String] = [],
        setupSDKPath: String? = nil
    ) {
        self.id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.compiler = compiler
        self.platform = platform
        self.buildContext = buildContext
        self.traits = traits
        self.setupModule = setupModule
        self.setupType = setupType
        self.setupCompilerFlags = setupCompilerFlags
        self.setupSDKPath = setupSDKPath
    }

    /// Run the full pipeline and return the compiled dylib path + literal map.
    public func compile() async throws -> CompileResult {
        state = .compiling

        do {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let previews = PreviewParser.parse(source: source)

            guard previewIndex >= 0, previewIndex < previews.count else {
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
                    let result = BridgeGenerator.generateOverlaySource(
                        originalSource: source,
                        closureBody: preview.closureBody,
                        previewIndex: previewIndex,
                        platform: platform,
                        traits: traits,
                        setupModule: setupModule,
                        setupType: setupType
                    )
                    compiledSource = result.source
                    literals = result.literals
                    additionalSourceFiles = srcFiles
                    moduleName = ctx.moduleName
                } else {
                    compiledSource = BridgeGenerator.generateBridgeOnlySource(
                        moduleName: ctx.moduleName,
                        closureBody: preview.closureBody,
                        platform: platform,
                        traits: traits,
                        setupModule: setupModule,
                        setupType: setupType
                    )
                    literals = []
                    additionalSourceFiles = []
                    moduleName = "PreviewBridge_\(ctx.moduleName)"
                }
                extraFlags = ctx.compilerFlags + setupCompilerFlags
            } else {
                // Standalone mode: setup not supported (no module system)
                let result = BridgeGenerator.generateCombinedSource(
                    originalSource: source,
                    closureBody: preview.closureBody,
                    previewIndex: previewIndex,
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
                additionalSourceFiles: additionalSourceFiles,
                overrideSDK: setupSDKPath
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

    /// Compile the preview for the JIT structural-reload path. Generates a render bridge
    /// with a baked PNG output path, compiles it to a `.o`, and returns the object plus the
    /// image path the agent will write. Standalone (combined-source) mode only for now.
    public func compileObjectForJIT() async throws -> JITRenderBuild {
        let source = try String(contentsOf: sourceFile, encoding: .utf8)
        let previews = PreviewParser.parse(source: source)

        guard previewIndex >= 0, previewIndex < previews.count else {
            throw PreviewSessionError.previewNotFound(
                index: previewIndex,
                available: previews.count
            )
        }
        let preview = previews[previewIndex]

        let stem = "previewsmcp-jit-\(id)-\(UUID().uuidString)"
        let imagePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stem).png")
        let valuesPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stem).json")

        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: source,
            closureBody: preview.closureBody,
            previewIndex: previewIndex,
            platform: platform,
            traits: traits,
            renderOutputPath: imagePath.path,
            designTimeValuesPath: valuesPath.path
        )

        let objectPath = try await compiler.compileObject(
            source: generated.source,
            moduleName: Self.moduleName(for: sourceFile)
        )
        try Self.writeDesignTimeValues(generated.literals, to: valuesPath)

        lastOriginalSource = source
        lastLiterals = generated.literals

        let build = JITRenderBuild(
            objectPath: objectPath,
            imagePath: imagePath,
            valuesPath: valuesPath,
            entrySymbol: "renderPreviewToFile",
            literals: generated.literals
        )
        lastJITBuild = build
        return build
    }

    /// Apply a literal-only edit to the agent-backed render: rewrite the design-time
    /// values JSON for the last JIT build so re-running its render entry reflects the
    /// new values, without recompiling. Returns the build to re-render, or nil if the
    /// session has no JIT build yet.
    public func applyLiteralValuesForJIT(
        _ changes: [(id: String, newValue: LiteralValue)]
    ) throws -> JITRenderBuild? {
        guard let build = lastJITBuild else { return nil }
        var dict =
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: build.valuesPath))
                as? [String: Any]) ?? [:]
        for change in changes {
            dict[change.id] = Self.anyValue(change.newValue)
        }
        try JSONSerialization.data(withJSONObject: dict).write(to: build.valuesPath)
        return build
    }

    /// Serialize design-time literal values to the JSON the render bridge seeds from.
    static func writeDesignTimeValues(_ literals: [LiteralEntry], to path: URL) throws {
        var dict: [String: Any] = [:]
        for entry in literals {
            dict[entry.id] = anyValue(entry.value)
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try data.write(to: path)
    }

    private static func anyValue(_ value: LiteralValue) -> Any {
        switch value {
        case .string(let s): return s
        case .integer(let n): return n
        case .float(let d): return d
        case .boolean(let b): return b
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

    /// Switch to a different preview index and recompile. Traits are preserved. @State is lost.
    /// Rolls back the index if compilation fails.
    public func switchPreview(to newIndex: Int) async throws -> CompileResult {
        let oldIndex = self.previewIndex
        self.previewIndex = newIndex
        do {
            return try await compile()
        } catch {
            self.previewIndex = oldIndex
            throw error
        }
    }

    /// Update traits and recompile. Returns the new dylib. @State is lost.
    ///
    /// - Parameters:
    ///   - traits: values to set on the session's current traits (merged —
    ///     non-nil values override, nil leaves the current value alone).
    ///   - clearing: fields to explicitly null out after the merge. This is
    ///     the only way to revert a previously-set trait; merging a nil
    ///     value preserves the old one.
    public func reconfigure(
        traits: PreviewTraits,
        clearing: Set<PreviewTraits.Field> = []
    ) async throws -> CompileResult {
        self.traits = self.traits.merged(with: traits).clearing(clearing)
        return try await compile()
    }

    /// Replace traits entirely (no merge) and recompile. Used by preview_variants
    /// where each variant must be absolute, not accumulated.
    public func setTraits(_ newTraits: PreviewTraits) async throws -> CompileResult {
        self.traits = newTraits
        return try await compile()
    }

    private static func moduleName(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let hash = String(stableHash(file.path), radix: 16).prefix(6)
        return "Preview_\(stem)_\(hash)"
    }

    /// FNV-1a hash producing a stable, deterministic value across processes.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3  // FNV prime
        }
        return hash
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
