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
    /// The generated `@_cdecl` window-state entry (`recordPreviewWindowState`), present for
    /// visible macOS sessions. The reloader runs it after a respawn handoff kills the outgoing
    /// agent, so the sidecar's last write describes the surviving window (#254).
    public let windowStateEntrySymbol: String?

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
        setupEntrySymbol: String? = nil,
        windowStateEntrySymbol: String? = nil
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
        self.windowStateEntrySymbol = windowStateEntrySymbol
    }
}

/// Orchestrates the full preview pipeline: parse → generate bridge → compile → return a JIT build.
/// Runs synchronous CPU-bound work (swift-syntax parsing / bridge codegen) off
/// the Swift cooperative pool, on the shared blocking-work queue. A JIT parse can take tens to
/// hundreds of ms; left on the cooperative pool it pins a pool thread for that
/// whole burst and — together with subprocess load — starves the daemon's MCP
/// request handlers, which is the preview_snapshot wedge observed under
/// concurrent stream load. Hopping it off the pool keeps a thread free to service
/// the snapshot handler.
public actor PreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public private(set) var previewIndex: Int

    private let compiler: Compiler
    private let platform: PreviewPlatform
    private var buildContext: BuildContext?
    private var traits: PreviewTraits
    private let setupModule: String?
    private let setupType: String?
    private let setupCompilerFlags: [String]
    private let setupSDKPath: String?
    private let setupDylibPath: URL?
    private var lastOriginalSource: String?
    private var lastJITBuild: JITRenderBuild?
    private var cachedStableModule: (key: [String: Date], module: Compiler.StableModule)?
    private var firedPathDamper = FiredPathDamper()
    private var canonicalTargetSources: Set<String>?
    private var evidenceIndex: EvidenceIndex?

    /// Burst-membership sets derived once per compile context — the
    /// evidence only changes on `replaceBuildContext`, not per fire.
    private struct EvidenceIndex {
        let definitions: Set<String>
        let runtime: Set<String>
        let rootPrefixes: [String]

        init(_ evidence: EvidenceSet) {
            definitions = Set(evidence.definitionFiles.map(\.path))
            runtime = Set(evidence.runtimeInputs.map(\.path))
            rootPrefixes = evidence.sourceDirectories.map { $0.path + "/" }
        }
    }

    public var currentTraits: PreviewTraits {
        traits
    }

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
        id = UUID().uuidString
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

    /// Where the generated `previewSetUp` entry records a thrown setUp
    /// error for the daemon to read (docs/phase-error-protocol.md).
    public nonisolated static func setupErrorSidecarPath(for id: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-setup-error-\(id).txt")
    }

    /// Take-and-clear the setup-failure notice, armed when a rendered
    /// session's `setUp()` threw (the entry wrote the sidecar and the
    /// preview rendered without setup). Same delivery discipline as the
    /// crash notice: reading consumes the sidecar.
    public nonisolated static func takeSetupFailureNotice(
        sessionID: String, setupType: String?
    ) -> Notice? {
        let sidecar = setupErrorSidecarPath(for: sessionID)
        guard let text = try? String(contentsOf: sidecar, encoding: .utf8) else { return nil }
        try? FileManager.default.removeItem(at: sidecar)
        let type = setupType ?? "setup"
        return Notice(
            code: .setupFailed,
            message: "Preview setup '\(type)' failed: \(text). The preview rendered without setup."
        )
    }

    /// A window placement (content rect) recorded by the agent for a session. The sidecar also
    /// carries a live key-status field, but that is written and read only by generated agent
    /// code (#254); the daemon never interprets or writes it.
    public struct WindowFrame: Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
    }

    /// The last window frame the agent recorded for this session, or nil when none was written.
    public nonisolated static func storedWindowFrame(for id: String) -> WindowFrame? {
        guard let data = try? Data(contentsOf: frameSidecarPath(for: id)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = obj["x"] as? Double, let y = obj["y"] as? Double,
              let width = obj["width"] as? Double, let height = obj["height"] as? Double
        else { return nil }
        return WindowFrame(x: x, y: y, width: width, height: height)
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
        let previews = await offCooperativePool { PreviewParser.parse(source: source) }

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

        // Setup wiring is independent of the Tier 2 split: a single-source
        // target (captured inputs exclude the preview file) must not
        // silently drop a configured setup (docs/phase-error-protocol.md,
        // T01/T03). The build-context requirement is the invariant the old
        // splitContext gate carried implicitly — standalone mode stays
        // excluded and warned.
        let hasSetup =
            BridgeGenerator.isUsableSetup(module: setupModule, type: setupType)
                && setupDylibPath != nil
                && buildContext != nil

        var stable: Compiler.StableModule?
        if let (ctx, bulk) = splitContext {
            let mark = ContinuousClock.now
            stable = try await stableModuleIfLeaf(for: bulk, context: ctx)
            Log.info(
                "jit_latency: stable-module \(stable == nil ? "non-leaf" : "leaf") "
                    + "\(Log.millis(mark, ContinuousClock.now))ms"
            )
        }

        // Snapshot the actor-isolated inputs into Sendable locals so the codegen
        // can run off the cooperative pool without touching actor state.
        let snapshotClosureBody = preview.closureBody
        let snapshotPreviewIndex = previewIndex
        let snapshotPlatform = platform
        let snapshotTraits = traits
        let snapshotSetupModule = hasSetup ? setupModule : nil
        let snapshotSetupType = hasSetup ? setupType : nil
        let snapshotRenderPath = imagePath.path
        let snapshotValuesPath = valuesPath.path
        let snapshotStableImport = stable != nil ? splitContext?.0.moduleName : nil
        let snapshotSidecarPath = Self.frameSidecarPath(for: id).path
        let snapshotSetupErrorPath = hasSetup ? Self.setupErrorSidecarPath(for: id).path : nil
        let generated = await offCooperativePool {
            BridgeGenerator.generateCombinedSource(
                originalSource: source,
                closureBody: snapshotClosureBody,
                previewIndex: snapshotPreviewIndex,
                platform: snapshotPlatform,
                traits: snapshotTraits,
                setupModule: snapshotSetupModule,
                setupType: snapshotSetupType,
                renderOutputPath: snapshotRenderPath,
                designTimeValuesPath: snapshotValuesPath,
                stableModuleImport: snapshotStableImport,
                renderWindow: window,
                frameSidecarPath: snapshotSidecarPath,
                setupErrorSidecarPath: snapshotSetupErrorPath
            )
        }

        let objectPath: URL
        var supportObjectPaths: [URL] = []
        var requiresFreshAgent = false

        // The JIT links the target's dependency archives/dylibs regardless of
        // which compile path runs (`splitContext.0` is `buildContext`, so the
        // flags are the same in both branches).
        let linkFlags = buildContext?.compilerFlags ?? []
        var archivePaths = Self.dependencyArchives(in: linkFlags)
        if let runtimeArchive = try await Toolchain.compilerRuntimeArchivePath() {
            archivePaths.append(URL(fileURLWithPath: runtimeArchive))
        }
        var dylibPaths = Self.dependencyDylibs(in: linkFlags)
        dylibPaths += buildContext?.frameworkPaths ?? []
        if let path = setupDylibPath, hasSetup {
            dylibPaths.insert(path, at: 0)
        }

        if let (ctx, bulk) = splitContext {
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
                    "jit_latency: incremental-compile \(Log.millis(mark, ContinuousClock.now))ms"
                )
                supportObjectPaths = built.bulkObjects
                objectPath = try Self.uniqueObjectCopy(of: built.overlayObject)
                requiresFreshAgent = true
            }
        } else {
            // No Tier 2 bulk (e.g. an `@main` target whose only other source is
            // the excluded entry-point file). Carry the build context's compiler
            // flags so the lone preview compile still finds its dependency
            // modules, and the setup flags so a wired setup's import resolves
            // exactly as it does on both split branches.
            objectPath = try await compiler.compileObject(
                source: generated.source,
                moduleName: "\(Self.moduleName(for: sourceFile))_\(Self.uniqueModuleToken())",
                extraFlags: linkFlags + setupCompilerFlags,
                overrideSDK: setupSDKPath
            )
        }
        try Self.writeDesignTimeValues(generated.literals, to: valuesPath)

        lastOriginalSource = source

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
            setupEntrySymbol: hasSetup ? "previewSetUp" : nil,
            windowStateEntrySymbol: window?.headless == false ? "recordPreviewWindowState" : nil
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
            } else if flag.hasPrefix("-l"), flag.count > 2 {
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
        case let .string(s): s
        case let .integer(n): n
        case let .float(d): d
        case let .boolean(b): b
        }
    }

    /// How a watcher-fired source change should be applied to a live preview session.
    public enum SourceChangeKind: Sendable {
        /// Content is byte-identical (or only reformats to identical literal values). The
        /// preview should be left untouched so live `@State` is preserved.
        case unchanged
        /// Only literal values changed. Re-render in place without recompiling.
        case literal([(id: String, newValue: LiteralValue)])
        /// The structure changed. Requires a full recompile / agent respawn.
        case structural
    }

    /// What a watcher burst owes the session (docs/state-invalidation.md
    /// stage 4). Ordered: a `reresolve` includes a `refresh`'s work, which
    /// includes a fast-path reload's.
    public enum WatchedBurstAction: Sendable {
        /// Burst confined to the primary file and existing target sources:
        /// today's unchanged/literal/structural classification applies.
        case fastPath(SourceChangeKind)
        /// Burst touched captured evidence: re-run the native build,
        /// re-capture, swap the compile context and watcher, then reload.
        case refresh
        /// Burst touched a project-definition file: re-run the ownership
        /// walk first, then proceed as a refresh.
        case reresolve
    }

    /// Tier a watcher burst against the session's captured evidence. Damping
    /// runs before tiering: an evidence path whose content is unchanged since
    /// its last fire is dropped, so a deterministic in-tree generator cannot
    /// feed a rebuild loop. An edit to an existing captured target source
    /// stays on the fast path; a removed one invalidates the captured source
    /// list itself and refreshes. Sessions without evidence delegate straight
    /// to today's classification.
    public func classifyWatchedBurst(
        firedPaths: Set<String>, canonicalPrimary: String, newPrimarySource: String
    ) -> WatchedBurstAction {
        guard let evidence = buildContext?.evidence else {
            return .fastPath(classifyWatchedChange(
                firedPaths: firedPaths, canonicalPrimary: canonicalPrimary,
                newPrimarySource: newPrimarySource
            ))
        }
        let index = evidenceIndex ?? {
            let fresh = EvidenceIndex(evidence)
            evidenceIndex = fresh
            return fresh
        }()
        let targets = targetSourceSet()

        var fastPathFired = Set<String>()
        var refreshHits = [String]()
        var reresolveHits = [String]()
        for path in firedPaths {
            if path == canonicalPrimary {
                fastPathFired.insert(path)
            } else if index.definitions.contains(path) {
                reresolveHits.append(path)
            } else if targets.contains(path) {
                if FileManager.default.fileExists(atPath: path) {
                    fastPathFired.insert(path)
                } else {
                    refreshHits.append(path)
                }
            } else if index.runtime.contains(path)
                || index.rootPrefixes.contains(where: { path.hasPrefix($0) })
            {
                refreshHits.append(path)
            } else {
                fastPathFired.insert(path)
            }
        }
        // Damp both tiers before deciding so every fired evidence path's
        // hash is recorded even when a higher tier wins the burst.
        let realReresolve = reresolveHits.filter { firedPathDamper.isRealChange($0) }
        let realRefresh = refreshHits.filter { firedPathDamper.isRealChange($0) }
        if !realReresolve.isEmpty { return .reresolve }
        if !realRefresh.isEmpty { return .refresh }
        return .fastPath(classifyWatchedChange(
            firedPaths: fastPathFired, canonicalPrimary: canonicalPrimary,
            newPrimarySource: newPrimarySource
        ))
    }

    /// Swap the compile context after a stage-4 refresh re-ran the native
    /// build. Clears the target-source set derived from the old context.
    /// The fired-path damper is deliberately kept: its records are what
    /// stop an in-tree generator's identical rewrite from re-triggering
    /// the refresh that just consumed it.
    public func replaceBuildContext(_ newContext: BuildContext?) {
        buildContext = newContext
        canonicalTargetSources = nil
        evidenceIndex = nil
    }

    private func targetSourceSet() -> Set<String> {
        if let canonicalTargetSources { return canonicalTargetSources }
        let set = Set((buildContext?.sourceFiles ?? []).compactMap {
            FileWatcher.canonicalPath($0.path)
        })
        canonicalTargetSources = set
        return set
    }

    /// Decide how a watcher burst should be applied. A burst that touched any SECONDARY
    /// watched file (a cross-file dependency) forces a structural reload, so a real cross-file
    /// edit is never dropped even when the primary file is in the same burst. Only a
    /// primary-only burst takes the unchanged or literal fast path. `firedPaths` and
    /// `canonicalPrimary` are canonical, resolved when the watch was installed.
    public func classifyWatchedChange(
        firedPaths: Set<String>, canonicalPrimary: String, newPrimarySource: String
    ) -> SourceChangeKind {
        if firedPaths.contains(where: { $0 != canonicalPrimary }) { return .structural }
        return classifySourceChange(newSource: newPrimarySource)
    }

    /// Three-way classification of the PRIMARY file's content, so an UNCHANGED file (a no-op
    /// editor save, an mtime touch, or an atomic-rename replay) is a no-op that preserves live
    /// `@State` instead of a structural reload that recompiles and respawns the agent. This does
    /// NOT advance the baseline, so a caller whose reload fails can retry on the next identical
    /// fire. Structural and literal reloads commit the baseline only on success. Content-equality
    /// is checked first so the unchanged case is caught even in Tier 1 (bridge-only, no thunks).
    public func classifySourceChange(newSource: String) -> SourceChangeKind {
        if lastOriginalSource == newSource { return .unchanged }
        guard let kind = literalDiff(newSource: newSource) else { return .structural }
        switch kind {
        case let .literalOnly(changes):
            return changes.isEmpty ? .unchanged : .literal(changes)
        case .structural:
            return .structural
        }
    }

    /// Record `source` as the live baseline after a reload applied it, so a later identical fire
    /// classifies as unchanged. Structural reloads set this via `compileObjectForJIT`. The literal
    /// fast path has no recompile, so its caller commits here once the re-render succeeds.
    public func commitSourceBaseline(_ source: String) {
        lastOriginalSource = source
    }

    /// Literal-vs-structural diff against the current baseline, without mutating it. Returns nil
    /// for Tier 1 (bridge-only, no thunks) and before the first compile sets a baseline.
    private func literalDiff(newSource: String) -> ChangeKind? {
        if let ctx = buildContext, !ctx.supportsTier2 { return nil }
        guard let oldSource = lastOriginalSource else { return nil }
        return LiteralDiffer.diff(old: oldSource, new: newSource)
    }

    /// Attempt a fast literal-only update. Returns changed literal IDs and new values,
    /// or nil if a structural recompile is needed.
    /// Returns nil for Tier 1 project mode (bridge-only, no thunks).
    public func tryLiteralUpdate(newSource: String) -> [(id: String, newValue: LiteralValue)]? {
        guard case let .literalOnly(changes) = literalDiff(newSource: newSource) else { return nil }
        lastOriginalSource = newSource
        return changes
    }

    /// Switch to a different preview index and recompile. Traits are preserved. @State is lost.
    /// Rolls back the index if compilation fails.
    public func switchPreviewForJIT(
        to newIndex: Int, window: JITRenderWindow? = nil
    ) async throws -> JITRenderBuild {
        let oldIndex = previewIndex
        previewIndex = newIndex
        do {
            return try await compileObjectForJIT(window: window)
        } catch {
            previewIndex = oldIndex
            throw error
        }
    }

    /// JIT counterpart of `reconfigure`: merge-and-clear traits, compile for the agent.
    public func reconfigureForJIT(
        traits: PreviewTraits,
        clearing: Set<PreviewTraits.Field> = [],
        window: JITRenderWindow? = nil
    ) async throws -> JITRenderBuild {
        self.traits = self.traits.merged(with: traits).clearing(clearing)
        return try await compileObjectForJIT(window: window)
    }

    /// JIT counterpart of `setTraits`: replace traits entirely, compile for the agent.
    public func setTraitsForJIT(
        _ newTraits: PreviewTraits, window: JITRenderWindow? = nil
    ) async throws -> JITRenderBuild {
        traits = newTraits
        return try await compileObjectForJIT(window: window)
    }

    /// A fresh, globally-unique module-name suffix (a valid Swift identifier) so the editable
    /// unit's classes (e.g. `DesignTimeStore`) mangle distinctly on every compile. Without it,
    /// the capped-persistent agent re-registers the same ObjC class across generations.
    private static func uniqueModuleToken() -> String {
        "g" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    }

    static func moduleName(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let hash = String(stableHash(file.path), radix: 16).prefix(6)
        return "Preview_\(sanitizedIdentifier(stem))_\(hash)"
    }

    /// File stems flow into `-module-name`, which must be a valid Swift
    /// identifier; spaces, dashes, and other punctuation in file names are
    /// mapped to underscores (the path-hash suffix keeps collisions apart).
    static func sanitizedIdentifier(_ stem: String) -> String {
        String(
            stem.map { character in
                character.isASCII
                    && (character.isLetter || character.isNumber || character == "_")
                    ? character : "_"
            }
        )
    }

    /// FNV-1a hash producing a stable, deterministic value across processes.
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325 // FNV offset basis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3 // FNV prime
        }
        return hash
    }
}

public enum PreviewSessionError: Error, LocalizedError, CustomStringConvertible {
    case previewNotFound(index: Int, available: Int)

    public var description: String {
        switch self {
        case let .previewNotFound(index, available):
            "Preview index \(index) not found. File has \(available) preview(s)."
        }
    }

    public var errorDescription: String? {
        description
    }
}
