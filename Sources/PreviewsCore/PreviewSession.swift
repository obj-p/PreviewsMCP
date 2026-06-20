import Foundation

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
    /// Prebuilt stable-module objects to link before `objectPath` (recompile-narrowing
    /// split). Empty for the standalone path, where `objectPath` is self-contained.
    public let supportObjectPaths: [URL]
    /// Static-library archives (the target's `-L`/`-l` dependency archives) the agent must
    /// link so the editable/stable objects' dependency symbols resolve. Empty for standalone.
    public let archivePaths: [URL]
    /// Binary dynamic libraries (the target's `-F`/`-framework` dependency frameworks) the
    /// agent must `dlopen` so their symbols resolve. Empty for standalone.
    public let dylibPaths: [URL]
    /// Require a freshly respawned agent for this render instead of a new generation on the
    /// live one. The non-leaf incremental split compiles under the target's own (stable) module
    /// name, so its `@Observable DesignTimeStore` would re-register across generations in one
    /// process; a fresh process each structural edit sidesteps the duplicate registration.
    public let requiresFreshAgent: Bool
    /// The generated `@_cdecl` setup entry (`previewSetUp`), present when the session has a
    /// setup plugin. The reloader runs it once per agent process before the first render.
    public let setupEntrySymbol: String?

    public init(
        objectPath: URL,
        imagePath: URL,
        valuesPath: URL,
        entrySymbol: String,
        literals: [LiteralEntry],
        supportObjectPaths: [URL] = [],
        archivePaths: [URL] = [],
        dylibPaths: [URL] = [],
        requiresFreshAgent: Bool = false,
        setupEntrySymbol: String? = nil
    ) {
        self.objectPath = objectPath
        self.imagePath = imagePath
        self.valuesPath = valuesPath
        self.entrySymbol = entrySymbol
        self.literals = literals
        self.supportObjectPaths = supportObjectPaths
        self.archivePaths = archivePaths
        self.dylibPaths = dylibPaths
        self.requiresFreshAgent = requiresFreshAgent
        self.setupEntrySymbol = setupEntrySymbol
    }
}

/// Orchestrates the full preview pipeline: parse → generate bridge → compile → return a JIT build.
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
    private let setupDylibPath: URL?
    private var lastOriginalSource: String?
    private var lastLiterals: [LiteralEntry]?
    private var lastJITBuild: JITRenderBuild?
    private var cachedStableModule: (key: [String: Date], module: Compiler.StableModule)?

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
        setupSDKPath: String? = nil,
        setupDylibPath: URL? = nil
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
        self.setupDylibPath = setupDylibPath
    }

    /// Session-stable path the agent's bridge writes the live window frame to, so a respawned
    /// agent can restore the user's dragged/resized window. Derived from the session id (not the
    /// per-compile stem) so it survives across respawns within one session.
    public nonisolated static func frameSidecarPath(for id: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-jit-frame-\(id).json")
    }

    /// The last window frame the agent recorded for this session, or nil when none was written.
    public nonisolated static func storedWindowFrame(
        for id: String
    ) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard let data = try? Data(contentsOf: frameSidecarPath(for: id)),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
            let x = obj["x"], let y = obj["y"], let width = obj["width"], let height = obj["height"]
        else { return nil }
        return (x, y, width, height)
    }

    /// Compile the preview for the JIT structural-reload path. Generates a render bridge
    /// with a baked PNG output path, compiles it to a `.o`, and returns the object plus the
    /// image path the agent will write.
    ///
    /// In Tier-2 project mode the compile is split (recompile-narrowing): the hot preview
    /// file is the editable unit, `@testable import`ing a stable module prebuilt from the
    /// target's other sources, so an edit recompiles only the hot file. Standalone mode
    /// compiles the self-contained combined source as one object.
    public func compileObjectForJIT(window: JITRenderWindow? = nil) async throws -> JITRenderBuild {
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

        let splitContext = buildContext.flatMap { ctx -> (BuildContext, [URL])? in
            guard ctx.supportsTier2, let bulk = ctx.sourceFiles, !bulk.isEmpty else { return nil }
            return (ctx, bulk)
        }

        let hasSetup =
            splitContext != nil
            && BridgeGenerator.isUsableSetup(module: setupModule, type: setupType)

        var stable: Compiler.StableModule?
        if let (ctx, bulk) = splitContext {
            let mark = ContinuousClock.now
            stable = try await stableModuleIfLeaf(for: bulk, context: ctx)
            Log.info(
                "jit_latency: stable-module \(stable == nil ? "non-leaf" : "leaf") "
                    + "\(Log.millis(mark, ContinuousClock.now))ms")
        }

        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: source,
            closureBody: preview.closureBody,
            previewIndex: previewIndex,
            platform: platform,
            traits: traits,
            setupModule: hasSetup ? setupModule : nil,
            setupType: hasSetup ? setupType : nil,
            renderOutputPath: imagePath.path,
            designTimeValuesPath: valuesPath.path,
            stableModuleImport: stable != nil ? splitContext?.0.moduleName : nil,
            renderWindow: window,
            frameSidecarPath: Self.frameSidecarPath(for: id).path
        )

        let objectPath: URL
        var supportObjectPaths: [URL] = []
        var archivePaths: [URL] = []
        var dylibPaths: [URL] = []
        var requiresFreshAgent = false
        if let (ctx, bulk) = splitContext {
            archivePaths = Self.dependencyArchives(in: ctx.compilerFlags)
            if let runtimeArchive = try await Toolchain.compilerRuntimeArchivePath() {
                archivePaths.append(URL(fileURLWithPath: runtimeArchive))
            }
            dylibPaths = Self.dependencyDylibs(in: ctx.compilerFlags)

            if let path = setupDylibPath, hasSetup {
                dylibPaths.insert(path, at: 0)
            }

            if let stable {
                supportObjectPaths = [stable.objectPath]
                let mark = ContinuousClock.now
                objectPath = try await compiler.compileObject(
                    source: generated.source,
                    moduleName: "PreviewEdit_\(ctx.moduleName)_\(Self.uniqueModuleToken())",
                    extraFlags: ["-I", stable.modulesDir.path] + ctx.compilerFlags
                        + setupCompilerFlags,
                    overrideSDK: setupSDKPath
                )
                Log.info("jit_latency: overlay-compile \(Log.millis(mark, ContinuousClock.now))ms")
            } else {
                // Non-leaf: the bulk references the edited file, so it cannot be prebuilt as a
                // one-directional stable module. Compile the whole module incrementally with the
                // overlay in-module (no `@testable import`); only the hot file recompiles per edit.
                let mark = ContinuousClock.now
                let built = try await compiler.compileModuleIncremental(
                    overlaySource: generated.source,
                    bulkFiles: bulk,
                    moduleName: ctx.moduleName,
                    extraFlags: ctx.compilerFlags + setupCompilerFlags,
                    overrideSDK: setupSDKPath
                )
                Log.info(
                    "jit_latency: incremental-compile \(Log.millis(mark, ContinuousClock.now))ms")
                supportObjectPaths = built.bulkObjects
                objectPath = try Self.uniqueObjectCopy(of: built.overlayObject)
                requiresFreshAgent = true
            }
        } else {
            objectPath = try await compiler.compileObject(
                source: generated.source,
                moduleName: "\(Self.moduleName(for: sourceFile))_\(Self.uniqueModuleToken())"
            )
        }
        try Self.writeDesignTimeValues(generated.literals, to: valuesPath)

        lastOriginalSource = source
        lastLiterals = generated.literals

        let build = JITRenderBuild(
            objectPath: objectPath,
            imagePath: imagePath,
            valuesPath: valuesPath,
            entrySymbol: "renderPreviewToFile",
            literals: generated.literals,
            supportObjectPaths: supportObjectPaths,
            archivePaths: archivePaths,
            dylibPaths: dylibPaths,
            requiresFreshAgent: requiresFreshAgent,
            setupEntrySymbol: hasSetup ? "previewSetUp" : nil
        )
        lastJITBuild = build
        return build
    }

    /// Resolve the `-L <dir>` / `-l<name>` pairs in `flags` to `<dir>/lib<name>.a` archive
    /// paths that exist on disk. These are the target's dependency archives the JIT agent
    /// must link so the editable/stable objects' cross-target symbols resolve (G3).
    static func dependencyArchives(in flags: [String]) -> [URL] {
        var searchDirs: [URL] = []
        var names: [String] = []
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if flag == "-L", index + 1 < flags.count {
                searchDirs.append(URL(fileURLWithPath: flags[index + 1]))
                index += 2
            } else if flag.hasPrefix("-l") && flag.count > 2 {
                names.append(String(flag.dropFirst(2)))
                index += 1
            } else {
                index += 1
            }
        }
        var archives: [URL] = []
        for name in names {
            for dir in searchDirs {
                let candidate = dir.appendingPathComponent("lib\(name).a")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    archives.append(candidate)
                    break
                }
            }
        }
        return archives
    }

    /// Resolve the `-F <dir>` / `-framework <name>` pairs in `flags` to the framework binary
    /// at `<dir>/<name>.framework/<name>`. These are the target's binary-framework deps the
    /// JIT agent must `dlopen` so their symbols resolve (G3-b).
    static func dependencyDylibs(in flags: [String]) -> [URL] {
        var searchDirs: [URL] = []
        var names: [String] = []
        var index = 0
        while index < flags.count {
            let flag = flags[index]
            if flag == "-F", index + 1 < flags.count {
                searchDirs.append(URL(fileURLWithPath: flags[index + 1]))
                index += 2
            } else if flag == "-framework", index + 1 < flags.count {
                names.append(flags[index + 1])
                index += 2
            } else {
                index += 1
            }
        }
        var dylibs: [URL] = []
        for name in names {
            for dir in searchDirs {
                let candidate = dir.appendingPathComponent("\(name).framework/\(name)")
                if FileManager.default.fileExists(atPath: candidate.path) {
                    dylibs.append(candidate)
                    break
                }
            }
        }
        return dylibs
    }

    /// Return the stable module for `bulk`, reusing the cached one when no bulk file has
    /// changed (the common case: repeated edits to the hot preview file). Rebuilds only when
    /// a bulk file's modification date changes, so the per-edit compile stays narrow.
    private var bulkIsNonLeaf = false

    /// The stable half of the leaf split, or nil when the bulk references the hot file (non-leaf)
    /// and so cannot compile without it. Cached per session: once the bulk fails to compile on its
    /// own, every later edit takes the incremental whole-module path. A genuine bulk error surfaces
    /// again from that path, so the fallback never hides it.
    private func stableModuleIfLeaf(
        for bulk: [URL], context ctx: BuildContext
    ) async throws -> Compiler.StableModule? {
        if bulkIsNonLeaf { return nil }
        do {
            return try await stableModule(for: bulk, context: ctx)
        } catch is CompilationError {
            bulkIsNonLeaf = true
            return nil
        }
    }

    /// Copy the incremental build's reused `overlay.o` (a stable path) to a unique path, so each
    /// structural edit presents a distinct `objectPath`. The reloader keys its literal fast path on
    /// object-path identity, which a stable path would falsely trigger.
    private static func uniqueObjectCopy(of object: URL) throws -> URL {
        let dest = object.deletingLastPathComponent()
            .appendingPathComponent("overlay-\(uniqueModuleToken()).o")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: object, to: dest)
        return dest
    }

    private func stableModule(
        for bulk: [URL], context ctx: BuildContext
    ) async throws -> Compiler.StableModule {
        let key = Self.bulkKey(bulk)
        if let cached = cachedStableModule, cached.key == key {
            return cached.module
        }
        let module = try await compiler.emitStableModule(
            sourceFiles: bulk,
            moduleName: ctx.moduleName,
            extraFlags: ctx.compilerFlags,
            overrideSDK: setupSDKPath
        )
        cachedStableModule = (key, module)
        return module
    }

    private static func bulkKey(_ bulk: [URL]) -> [String: Date] {
        var key: [String: Date] = [:]
        for file in bulk {
            let date =
                (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
                    as? Date) ?? .distantPast
            key[file.path] = date
        }
        return key
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

    /// Apply a preview-index switch around `compile`, rolling the index back if it throws.
    /// Used by the JIT switch path to keep index mutation and rollback in one place.
    private func withPreviewIndex<T>(
        _ newIndex: Int, compile: () async throws -> T
    ) async throws -> T {
        let oldIndex = previewIndex
        previewIndex = newIndex
        do {
            return try await compile()
        } catch {
            previewIndex = oldIndex
            throw error
        }
    }

    /// The single definition of configure-merge semantics for the JIT path.
    private func applyReconfigure(traits: PreviewTraits, clearing: Set<PreviewTraits.Field>) {
        self.traits = self.traits.merged(with: traits).clearing(clearing)
    }

    /// Switch to a different preview index and recompile. Traits are preserved. @State is lost.
    /// Rolls back the index if compilation fails.
    public func switchPreviewForJIT(
        to newIndex: Int, window: JITRenderWindow? = nil
    ) async throws -> JITRenderBuild {
        try await withPreviewIndex(newIndex) { try await compileObjectForJIT(window: window) }
    }

    /// JIT counterpart of `reconfigure`: merge-and-clear traits, compile for the agent.
    public func reconfigureForJIT(
        traits: PreviewTraits,
        clearing: Set<PreviewTraits.Field> = [],
        window: JITRenderWindow? = nil
    ) async throws -> JITRenderBuild {
        applyReconfigure(traits: traits, clearing: clearing)
        return try await compileObjectForJIT(window: window)
    }

    /// JIT counterpart of `setTraits`: replace traits entirely, compile for the agent.
    public func setTraitsForJIT(
        _ newTraits: PreviewTraits, window: JITRenderWindow? = nil
    ) async throws -> JITRenderBuild {
        self.traits = newTraits
        return try await compileObjectForJIT(window: window)
    }

    /// A fresh, globally-unique module-name suffix (a valid Swift identifier) so the editable
    /// unit's classes (e.g. `DesignTimeStore`) mangle distinctly on every compile. Without it,
    /// the capped-persistent agent re-registers the same ObjC class across generations.
    private static func uniqueModuleToken() -> String {
        "g" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
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
