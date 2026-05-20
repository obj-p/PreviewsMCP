# PreviewsPipeline.framework — Architecture Diagram (Draft 1)

**Source data:** `research/scripts/data/previews-pipeline-exports.txt` (6,723 swift-demangled
exports from `Xcode.app/Contents/SharedFrameworks/PreviewsPipeline.framework`, Xcode 26.2).

**Purpose:** W2 deliverable per `prompts/jit-executor-research.md`. For each Apple pipeline
sub-system, propose a public-layer analogue (LLVM JITLink/ORC, `swiftc -emit-object`, Mach-O
loader semantics, public JIT entitlement) that delivers equivalent semantics without depending
on private Apple frameworks.

**Status:** First draft. Confidence is uneven across sections — each claim is annotated. Loud
caveat up front: the "15-step pipeline" name list (`WorkCollectionStep`,
`WorkspaceBuildStep`, …) in `docs/reverse-engineering.md:569-577` **does not appear as Swift
type names in this dump.** Only `PreviewPreprocessingStep` and `PreviewSelectionPreprocessingStep`
are exposed as `Step`-suffixed Swift symbols. The names in that older doc are almost certainly
**signpost / log-event labels** emitted at runtime, not Swift types. Sections 2 and 3 below
re-frame the "pipeline" around the actual Swift types we see.

---

## 1. Inferred top-level type catalog

249 distinct `PreviewsPipeline.*` top-level types in the dump. The sub-groups below cover the
load-bearing ones; many small helpers (geometry, identifiers, error types) are omitted.

### 1.1 Pipeline core (the engine itself)

- **`Pipeline`** — class. Allocating initializer takes a single `ResourceGraph` parameter
  (`Pipeline.__allocating_init(resourceGraph:)`). Owns a `PipelineEventLogger` and a
  `ResourceGraph.DependencyEditor`. Has a static `Pipeline.isEnabled` user-default flag.
  Interpretation: the pipeline is **not a fixed array of named steps** — it is a graph engine
  driven by `ResourceGraph` dependency edges. Steps appear as graph nodes / queries that
  fire when their inputs invalidate.
- **`ResourceGraph` / `ResourceGraphNode` / `ResourceGraphNodeProviding` / `ResourceGraphMarkerNode`
  / `ResourceGraphSeededMarkerNode` / `ResourceGraphSnapshot` / `ResourceDependencies`** —
  the dependency-graph substrate. `ResourceGraph.EditorContext.invalidate(nodesOf:where:...)`,
  `ResourceDependencies.guaranteedUniqueNode(of:where:create:)`, and
  `ResourceGraph.InvalidationReason` confirm a classic incremental-build / demand-driven
  recomputation engine ("query system"). The `Query` protocol is supplied by `PreviewsFoundationHost`
  (see `PreviewSelectionPreprocessingStepQuery : PreviewsFoundationHost.Query`). The pattern is
  identical to Bazel's Skyframe or rustc's salsa query systems.
- **`PipelineEventLogger`, `PipelineEventID`, `PipelineRawEvent`, `PipelineEventData`,
  `PipelineEventSignpost`, `PipelineEventTranscript`, `PipelineActiveEventToken`** —
  os_signpost / structured-event tracing wrapper. `PipelineEventSignpost.signpostName : StaticString`
  is the protocol requirement; **this is almost certainly the source of the "step" names
  observed in `docs/reverse-engineering.md:569-577`.** Confirming this needs a runtime
  `log stream --predicate 'subsystem == "com.apple.PreviewsPipeline"'` capture (see Section 4).
- **`PipelineTimeout`, `PipelineBuildingState`, `PreviewsPipelineTimingConfiguration`,
  `PipelineDefaults`** — pipeline-level configuration and timeout policy.

### 1.2 Workspace + graph abstractions ("what to build")

- **`WorkspaceBuilder`** — protocol. Carries `WorkspaceBuildIdentifier` / `GraphSource` /
  `DestinationRepresentation` associated types. Extensions provide `compile(code:for:buildTarget:
  queryManager:workspaceBuildIdentifier:workspaceBuildOutput:) async throws ->
  CodeGenerationIntelligence.CompilationResult` and `thunkRecipe(...)` /
  `xojitThunkRecipe(...)` / `dylibThunkRecipe(...)` factory methods. This is the central
  abstraction for "how a workspace produces preview products."
- **`SingleFileWorkspaceBuilder` / `SingleFileWorkspaceBuilderProtocol`** — concrete
  workspace flavor whose graph source is a single Swift file (used for #Preview-in-file
  scenarios). Init takes `defaultDestinationPreferences`, `moduleCacheDirectory`, `thunkKind`,
  `buildableTranslationUnits`, `filesWithDisabledThunking`, `runDestinations`,
  `extensionThunkBuildSettingsProviders`.
- **`WorkspaceGraph<UpdateGraphItem<A>>` / `WorkspaceGraph.Node` / `WorkspaceGraph.Subgraph` /
  `WorkspaceGraph.Constructor`** — directed graph of build items. Operations include
  `depthFirstNodeSequence`, `rootNodes`, `leafNodes`, `firstCommonAncestors`, `allPaths`,
  `makeUpdateGraph`. This is the dependency DAG that the build steps walk.
- **`UpdateGraphItem` / `BuildGraphItem`** — node payloads, identical field sets:
  `buildable`, `name`, `sourceFile`, `executionPointPack`, `executionPointSource`, `description`.
- **`WorkspaceGraphSource`** — protocol with `agentBundle(for:Node, with:HostType)`,
  `dynamicallyLoadableProduct(for:Node)`, `module(for:Node)`, `preferredHostNode(in:)`,
  `supportedHostTypes(for:)`. This is the "interpret a graph node" surface.
- **`WorkspaceBuildArena` / `WorkspaceBuildContext` / `WorkspaceBuildThrottler` /
  `PathPrefixedBuildArena` / `TemporaryBuildArena`** — filesystem build sandbox where artifacts
  are emitted.

### 1.3 Recipes (build procedures)

- **`PreviewRecipe`** — protocol. Requirements: `build(for:in:prerequisiteProducts:queryManager:)
  -> Future<PreviewProduct>`, `capabilities : UpdateCapabilities`,
  `debugBuildCommandDescription : String`. Two known concrete implementations:
  - **`DylibPreviewRecipe`** — init takes `code`, `module`, `dependentModule`,
    `dependentExecutableName`, `frameworkModulesToLink`, `buildWithCompilerBasedThunking: Bool`,
    `shouldEmitModule: Bool`, `sourceIdentifier`, `capabilities`, `signingInformation`,
    `buildConfigurationProvider: DylibBuildConfigurationProvider`, `unresolvedRegistryLocationMap`,
    `extensionThunkBuildSettingsProviders`. Produces a standalone preview `.dylib` (the
    pre-Xcode-16 `@_dynamicReplacement` style thunk).
  - **`XOJITThunkPreviewRecipe`** — uses `XOJITThunkBuildConfigurationProvider` and emits an
    object file (`.o`) plus a thunk source file rather than a linked dylib. Produces a
    `PreviewProduct` consumed by the JIT executor.
- **`PreviewRecipeGenerator` / `PreviewRecipeGeneratorProtocol` / `PreviewRecipeGroup`** —
  factories that go from a `PreviewUpdatePlan.AgentRecord.SourceFileRecord` plus
  translation-unit info to a concrete recipe.
- **`DylibPreviewRecipe` / `XOJITThunkPreviewRecipe` / `TestWorkspacePreviewRecipe`** —
  recipe flavors. The presence of all three side-by-side in the dump (Xcode 26.2)
  matches the empirical finding in `docs/reverse-engineering.md:160-181`: both Dylib (legacy)
  and XOJIT (current) paths are still shipped, with JIT as the default.

### 1.4 Build configurations + linker plumbing

- **`DylibBuildConfiguration` / `DylibBuildConfigurationProvider` /
  `HandcraftedDylibBuildConfigurationProvider`** — args+paths for the legacy compiler-driven
  thunk build. Init exposes `thunkSourceDestination, thunkObjectFileDestination,
  thunkLibraryDestination, compilerPath, baseCompilerArguments, linkerPath, baseLinkerArguments,
  codesignAllocatePath, moduleSuffix, toolWorkingDirectoryPath` — i.e. it shells out to
  swiftc + ld + codesign_allocate.
- **`XOJITThunkBuildConfiguration` / `XOJITThunkBuildConfigurationProvider` /
  `HandcraftedXOJITThunkBuildConfigurationProvider` / `XOJITThunkBuilder`** — analogous
  config for the JIT path. Nested `XOJITThunkBuildConfiguration.CompilerArguments` (with optional
  `ResponseFile`) and `thunkSourceDestination`/`thunkObjectFileDestination` URLs. Concrete static
  builder: `XOJITThunkBuilder.build(code: String, sourceIdentifier:, thunkSourceDestination:,
  thunkObjectFileDestination:, compilerPath:, compilerArguments:, toolWorkingDirectoryPath:)
  -> Future<()>`. **Note: no linker path / linker args here** — confirms that for XOJIT, only
  the swiftc-to-`.o` step runs host-side; linking is done by the agent's JIT linker.
- **`PreviewsJITLinkerParameters`** — fields: `additionalArtifactPaths`, `architectures`,
  `installName`, `linkerFlags`, `loadCommands`, `objectFilePaths`, `outputPath`,
  `platformVersion`, `rpaths`, `staticLibraryPaths`, `unknownLinkerArguments`,
  `workingDirectory`, plus nested `PlatformVersion { name, minVersion }`. **This is the
  message-shape Xcode sends to the agent's JIT linker** — it's a serialized linker
  invocation. Crucially, `loadCommands` and `linkerFlags` are arrays of strings (we'd want
  to verify byte layout via lldb).
- **`LinkerArgumentIngestor` / `LinkerArgumentNormalizerDataSource` / `CachingLinkerDataSource`
  / `DirectLinkerDataSource` / `LinkerArguments` (with nested `AutolinkArgument`,
  `LinkingArgument`, `SearchPathArgument`) / `LinkerTool` / `ResponseFileArgumentParser` /
  `ResponseFileArgumentWriter`** — full linker-argument parsing + caching pipeline.
  Interpretation: Xcode parses the *real* linker command line emitted by the stable build,
  normalizes it, and reshapes it into `PreviewsJITLinkerParameters` for the agent. The
  "caching" + "direct" data sources are the two-tier cache for unchanged-vs-changed link
  inputs.
- **`MachOParsing`** (namespace, exposed as nested type names): `LinkerData`, `MachObject`,
  `LoadCommand`, `MachOFileIsLLVMBitcode`, `UnknownArchitecture`,
  `UnsupportedPlatformForMachOParsing`, `FailedParsingMachObjectFile`, `parse`,
  `supportedArchitectures`. Confirms host-side Mach-O introspection (used to compute hashes /
  validate inputs / extract link commands).

### 1.5 Products (build outputs)

- **`PreviewProduct`** — **enum** (confirmed by `enum case for PreviewsPipeline.PreviewProduct.
  preLinked(...)` and `.runtimeLinked(...)`). Two cases:
  - **`.preLinked(PreLinked)`** — the host pre-linked a dylib (`builtPath`,
    `executablePath`, `linkingStrategy`, `dynamicLoadingStrategy`, `externalFunctionBinding`,
    `signingInformation`, `registryLocationMap`). Used by the legacy Dylib path and by full-binary
    builds.
  - **`.runtimeLinked(RuntimeLinked)`** — only `seed, isRequired, module,
    builtTargetDescriptions, registryLocationMap`. **No path fields** — the artifact is
    object code, not a finished dylib; final link happens runtime-side. This is the XOJIT
    payload shape.
- **`PreviewProductGroup` / `WorkspaceGraphLoadableProduct` / `DynamicLoadableProductDescriptor`
  (just a `url: Foundation.URL`)** — collections / descriptors handed to the agent at update
  time, telling it which files to load.
- **`ThunkProduct` / `ThunkFuture` / `ThunkKind` / `BuildCacheThunkEntry`
  / `ThunkAuxiliaryBuildSettings` / `ThunkAuxiliaryBuildSettingsProvider`** — thunk-specific
  product/handle types. `ThunkKind` is an enum with cases `.dynamicReplacement` and `.jit`
  (confirmed via `enum case` symbols).
- **`BuildProductsCache`** — caches both workspace-level and thunk-level products keyed by
  `SourceIdentifier`. Methods include `launchThunkProduct`, `additionalThunkProducts`,
  `cacheTranslationUnit`, `apply(_:PreviewBuildDiff, forTranslationUnitIdentifiedBy:)`,
  `staleThunkIdentifiers`. This is **the** incremental-build state.

### 1.6 Update plans + sessions ("what happens this tick")

- **`PreviewUpdatePlan<GraphSource, BuildIdentifier, Destination>`** — generic record-style
  plan. Static factory: `planForUpdating(in: WorkspaceGraph<UpdateGraphItem<A>>,
  queryManager:, workspaceBuilder:) throws -> Future<PreviewUpdatePlan>`. Nested:
  - **`AgentRecord`** with fields: `agent`, `hostProvider`, `moduleNodes`, `loadableProducts`,
    `sourceFiles : [SourceIdentifier : SourceFileRecord]`, `executionPointPacks`, `role`,
    `jitLinkDescription`.
  - **`AgentRecord.SourceFileRecord`** — `sourceIdentifier`, `compileNode`, `linkNode`.
    The split confirms compile and link are **distinct nodes in the graph**, with `linkNode`
    being `Optional` (the JIT path has no host-side link node).
  - **`AgentRecord.JITLinkDescription`** — `nodes: OrderedIdentifiedSet<...Node>`, `empty`,
    `describe`. Holds the subgraph that gets sent to the JIT linker.
  - **`AgentRecord.PackRecord`** — `id: ExecutionPointPack`, `pack: ExecutionPointPack`.
  - **`AgentRecord.LoadableProduct`** — `product: A.LoadableProduct`, `id: Int`.
  - **`UpdateRecord`** — `id, agentRecord, destination, destinationRepresentation,
    workspaceBuildIdentifier`.
- **`PreviewUpdateSession<A>`** — runs a single plan. Has `requests`, `cancel`,
  `incrementallyUpdate(with: [SourcedIncrementalUpdate], replacingExecutionPointsWith:,
  analyticsLogger:) -> Result<PreviewUpdateSession, IncrementalUpdateError>`,
  `updatePlan`, `timingRecordID`. Each `Request` carries `agent`, `firstPass`, `passes`,
  `Pass`, `productsFuture`, `executionPoint`, `destinationFuture`, `updaterFuture`,
  `updateKind`, `BuiltProductParameters`.
- **`PreviewBuildDiff` (+ `Discriminant`, `MultiDiff`) / `SourcedIncrementalUpdate` /
  `IncrementalUpdateError`** — the diff machinery driving incremental rebuilds. Properties
  `canIncrementallyUpdate`, `shouldClearAllProducts`, `incrementalUpdates`, `severityOrder` map
  directly onto the small/middle/large rebuild tiers documented in
  `docs/reverse-engineering.md:558-567`.
- **`PreviewUpdatePlanPrintOptions`, `PreviewUpdateKind`, `PreviewUpdateReason`,
  `PreviewServiceUpdateQueue`, `UpdateQueueGroup`, `UpdateQueueGroupTrigger`,
  `UpdateTimeoutGroup`** — scheduling / debounce / queueing around update sessions.

### 1.7 Execution points (what's actually being run)

- **`ExecutionPoint`** — protocol. Required getters: `typeDescription`, `instanceDescription`,
  `source: ExecutionPointSource`, `updateBehavior: UpdateBehavior<Output>`, `agentWork:
  PreviewAgentWork`, `properties: ExecutionPointProperties`. Plus an associated `Output` type.
- Concrete subtypes: `PreviewExecutionPoint`, `PreviewProviderExecutionPoint`,
  `PreviewPreflightExecutionPoint`, `RegistryExecutionPoint`, `RegistryPreflightExecutionPoint`,
  `CFunctionExecutionPoint`, `ScheduledExecutionPoint`. Plus the type-erased `AnyExecutionPoint`.
- **`ExecutionPointSource` / `ExecutionPointHandle` / `ExecutionPointPack` /
  `ExecutionPointStatus` / `ExecutionPointUpdate` / `ExecutionPointScheduler` /
  `ExecutionPointObserver` / `ExecutionPointOrigin` / `ExecutionPointTimeout` /
  `ExecutionPointAnalyticsInfo` / `ExecutionPointProperties` /
  `GloballyUniqueExecutionPointIdentifier`** — the supporting cast. `ExecutionPoint.update(...)`
  extension takes `updater: UpdaterProtocol, destination, destinationParameters,
  destinationCapabilities, platformContext, containingModule, executionPointIdentifier,
  updateSeed, groupIdentifier, passCapabilities, setupPayload, isIncremental, agentBundle,
  agentProcess, symbolicationParameters, registryLocationMap, usingPipelineV2 : Bool`.
  Note the `usingPipelineV2` flag — Apple is mid-migration to a v2 pipeline internally.

### 1.8 Updaters (the agent-facing dispatch surface)

- **`PreviewUpdater`** — protocol with `agentBundle`, `identifier`, `pid: Int32`, `update(
  executionPoint: AnyExecutionPoint, in: WorkspaceIdentifier, sessionID:, products:
  ProductLoadingParameters, incrementalUpdates: [SourcedIncrementalUpdate]) -> Future<
  ExecutionPointUpdate>`, `applyIncrementalUpdates`, `relinquish`, `teardown`, `kill`. This
  is the host-side handle for a running agent.
- **`PreviewUpdaterStore<A,B>`** — pool / reuse of updaters with `PurgeStrategy`,
  `CheckoutResult`, `updaterLimit: PreviewUpdaterLimit`. `checkoutUpdater(matching: B,
  purgeStrategy:, makeUpdater: (Identifier) -> Future<A>)`. This is where agent reuse policy
  lives (and likely the basis for the "long-lived agent" property our research target wants).
- **`PreviewUpdaterDescription` / `AppHostedUpdaterDescription` /
  `PreviewUpdaterConnection` / `PreviewUpdaterLaunchResult` (enum, `.launched(PreviewUpdater)`
  case observed) / `PreviewUpdaterTeardownAction`** — agent lifecycle types.
- **`PreviewAgent`** — protocol with `run(executionPoint:, in:GroupIdentifier, with:
  UpdatePassCapabilities, workspace:, products: ProductLoadingParameters, incrementalUpdates:)
  async throws -> ExecutionPointUpdate`, `stopRunning(executionPointID:, in:)`.
- **`PreviewAgentBundle`** — value type. `init(identifier, url, executableURL, version,
  signingInformation, cdHash, architecture, librariesToInsert: Set<String>, usesInternalSDK:
  Bool, builtTargetDescriptions)` plus `runMode: PreviewAgentRunMode`. `PreviewAgentRunMode`
  is an **enum with cases `.dynamicReplacement`, `.jitExecutor`, `.fullBinary`** — matches
  the runMode flag observed at `docs/reverse-engineering.md:177-181`.
- **`PreviewAgentProcess`** — `init(pid:Int32, processExit:Future<()>, stop:@Sendable () -> ())`.
- **`PreviewDeviceAgentInstaller`** — class. `install(_:PreviewAgentBundle, on:AnyDevice,
  willInstall:) -> Future<InstallResult>`, where `InstallResult` has `path, didInstall, seed,
  destinationFilePathMap`. Device-side bundle deployment.
- **`PreviewAgentCache` / `PreviewAgentIdentifier` / `PreviewAgentInstallSeed` /
  `PreviewAgentWork` / `PreviewAgentLaunchEnvironmentAttribute` / `AssignedPreviewAgent` /
  `AgentLaunchConfiguration` (init: `bundle, dynamicallyLoadableProducts: [
  DynamicLoadablePreviewProduct], requiredLaunchThunks: Set<SourceIdentifier>`) /
  `LaunchEnvironment`** — the agent-launch supporting cast.
- **`InjectionFramework`** — `init(path:)` + `static unused`. Tiny wrapper around the path
  to `PreviewsInjection.framework` injected at agent launch (`DYLD_INSERT_LIBRARIES`).

### 1.9 Service / observer layer

- **`PreviewService`** — class. `init<A, B>(builderProvider: A, queryManager, workspaceIdentifier,
  resourceGraph, analyticsLogger, timingConfiguration)`. Methods include `compile(code:,as:) async
  throws -> CodeGenerationIntelligence.CompilationResult`, `setNeedsUpdate`, `pause`,
  `invalidate`, `registerDataSource`, `makeRunningAppPreviewManager`, `executionPointUpdateEvents`,
  `updateGroups`. Nested: `UpdateGroup` (with `UpdateEvent`, `UpdateOutcome`, `allEvents`,
  `diffs`, `previewEvents`, `translationUnits`, `filterEvents`), `ExecutionPointUpdateEvent`,
  `DataSource`, `DataSourceContext`, `UpdateIdentifier`. **This is the top-level façade Xcode
  drives.**
- **`PreviewServiceObserver` / `PreviewServiceBuilderProvider`** — observer protocols.
  `executionPointWillUpdate(_:AnyExecutionPoint, bundle:PreviewAgentBundle,
  loadableProductDescriptors:[DynamicLoadableProductDescriptor])` is the host-side hook for "I'm
  about to ask the agent to refresh."

### 1.10 Cross-cutting: registries, destinations, capabilities

- **Sources:** `WorkspaceGraphSource`, `SingleFileGraphSource`, `ProviderSource`,
  `ExecutionPointSource`, `AgentMessageStreamSource`, `CachingLinkerDataSource`,
  `DirectLinkerDataSource`, `LinkerArgumentNormalizerDataSource`. The "Source" suffix is
  consistently "input-side data provider"; not the same as "Step."
- **Destinations:** `RunDestination`, `RunDestinationInfo`, `RunDestinationProperties`,
  `RunDestinationRecipe`, `RunDestinationRecipePair`, `RunDestinationMatchingResult`,
  `AnyPreviewDestination`, `PreviewDestination`, `AnyRunDestinationRecipe`,
  `DestinationCapabilitiesCache`, `DestinationPreferences`, `DestinationRequirements`,
  `DestinationMode`, `SingletonDestinationParameters`, `AnyDevice`, `DeviceFamily`,
  `DeviceCategory`, `DeviceIdentifier`, `DevicePowerState`. The "where does this run" surface.
- **Registries:** `RegistryConfiguration`, `RegistryExecutionPoint`,
  `RegistryExecutionPointProtocol`, `RegistryExecutionPointProvider`, `RegistryLocationMap`,
  `RegistryMetadata`, `RegistryPreflightExecutionPoint`, `RegistryPreflightExecutionPointProtocol`,
  `RegistryPreflightRequest`, `RegistryPreviewDefinition`, `RegistryPreviewInstance`,
  `RegistryCapabilities`, `RegistryProtocol`, `RegistryExecutionOptions`,
  `UnresolvedRegistryLocationMap`. This is how `#Preview` macro registrations resolve at
  runtime — a registry keyed by source location.
- **Capabilities & behavior:** `UpdateCapabilities` (+ `Capability`), `UpdatePassCapabilities`,
  `UpdateBehavior<Output>`, `ValidateAction`. Negotiation between platform/host and what an
  update can attempt.
- **Platforms & SDKs:** `Platform`, `PlatformDefinition`, `PlatformIdentifier`,
  `PlatformPreviewUpdateContext`, `SDK`, `SDKVariantSpecification`, `Architecture`,
  `ToolchainDescription`, `ToolchainQuery`.
- **Preprocessing (the actual `Step` types):** `PreviewPreprocessingStep` (protocol) with
  `changesForTransforming(modelItem:ModelItem, at:ModelPath, in:NestedTypeDeclarationScope)
  -> (prefixes:[ModelChange], suffixes:[ModelChange])`. `PreviewSelectionPreprocessingStepQuery
  : PreviewsFoundationHost.Query`. Interpretation: preview-thunk source-code rewriting
  (e.g., the `__designTime*` substitution from `docs/reverse-engineering.md`).

---

## 2. The "15-step pipeline" — re-grounded

The name list from `docs/reverse-engineering.md:569-577` doesn't correspond to Swift type
names in this dump. Working hypothesis: those are **`PipelineEventSignpost` names emitted at
runtime** by the graph engine as nodes fire. The Swift types organize the *capabilities* the
graph needs; the signposts label the *temporal slices* of a single update tick.

Mapping the doc's signpost-style names to the Swift types in the dump (best-effort, **needs
runtime confirmation via `log stream`** — see Section 4):

| Doc signpost name | Most likely Swift backing |
|---|---|
| WorkCollectionStep | `PreviewService.setNeedsUpdate` + `PreviewServiceUpdateQueue` + `UpdateQueueGroup` / `UpdateQueueGroupTrigger` |
| WorkspaceBuildStep | `WorkspaceBuilder` traversal + `BuildProductsCache.workspaceProduct(for:noProductHandler:)` |
| BuiltTargetDescriptionsStep | `[BuiltTargetDescription]` (in `PreviewsMessagingHost`) attached on `PreviewProduct.RuntimeLinked` and `PreviewAgentBundle` |
| BuiltProductContextStep | `WorkspaceBuildContext<A>` |
| LaunchConfigurationStep | `AgentLaunchConfiguration.init(bundle:dynamicallyLoadableProducts:requiredLaunchThunks:)` |
| RunDestinationStep | `RunDestinationRecipePair` / `RunDestinationMatchingResult` |
| CodeCompilationStep | umbrella for the three below |
| ↳ CompileBuildStep | `XOJITThunkBuilder.build(code:...)` → emits `.o` |
| ↳ LinkBuildStep | `PreviewsJITLinkerParameters` (handed to agent) — host-side has no link node for XOJIT (see `SourceFileRecord.linkNode : Node?`) |
| ↳ EmitModuleBuildStep | `DylibPreviewRecipe.shouldEmitModule: Bool` (for the Dylib path) |
| DynamicLibraryBuildStep | `PreviewProduct.PreLinked` materialization via `DylibPreviewRecipe` |
| CodeSignBuildStep | `CodeSigningInformation` + `DylibBuildConfiguration.codesignAllocatePath` |
| LaunchThunksStep | `BuildProductsCache.launchThunkProduct(...)` + `AgentLaunchConfiguration.requiredLaunchThunks` |
| ↳ ThunkProductsStep | `ThunkProduct` / `ThunkFuture` (per-source-file) |
| ↳ VerifyThunkPresenceBuildStep | not visible as a discrete symbol; presumably a verifier inside the graph (could be a `ResourceGraph` invalidation rule) |
| AgentAssignmentStep | `PreviewUpdaterStore.checkoutUpdater(matching:purgeStrategy:makeUpdater:) -> CheckoutResult` + `AssignedPreviewAgent` |
| ExecutionPointUpdateStep | `ExecutionPoint.update(using:UpdaterProtocol, destination:, ..., usingPipelineV2:Bool)` |
| PerformUpdateStep | `PreviewUpdater.update(executionPoint:in:sessionID:products:incrementalUpdates:) -> Future<ExecutionPointUpdate>` (the actual IPC to the agent) |

Notes on ambiguity:
- `VerifyThunkPresenceBuildStep` has no obvious Swift type. Either it's a check folded into
  `BuildProductsCache` or a `ResourceGraph` query node. dtrace probe on signposts would
  pin it down quickly.
- The `LinkBuildStep` mapping is the most important hint of the whole dump for our purposes:
  on the JIT path it does **not** correspond to a host-side step at all — the host packages
  `PreviewsJITLinkerParameters` plus a set of `.o` paths and hands them to the agent's
  `PreviewsInjection` framework, which performs the actual link via XOJIT. The
  `SourceFileRecord.linkNode : Node?` being optional is the smoking gun.
- The split between `ExecutionPointUpdateStep` and `PerformUpdateStep` is fuzzy. Best guess:
  the former is host-side scheduling/queueing of an update; the latter is the IPC round-trip.
- The doc's "15-step" count looks fragile — `CodeCompilationStep` and `LaunchThunksStep` are
  written as umbrella names that decompose into nested steps. The actual signpost count may
  differ.

---

## 3. Public-layer analogue table

Rows track Apple sub-system to public-layer analogue. "Effort note" is a rough relative
sizing only; firm numbers come from W2's JITLink POC.

| Apple sub-system / signpost | What it does | Our public-layer analogue | Implementation effort note |
|---|---|---|---|
| `Pipeline` + `ResourceGraph` (graph engine, invalidation, queries) | Demand-driven dependency-graph engine. Nodes are queries; edits invalidate downstream nodes. | Roll our own incremental query system (salsa-style) on top of Swift `actor`s, **or** vendor an existing one (e.g. `swift-build`'s `llbuild` — already public, used by SwiftPM). | Medium. `llbuild` is the obvious fit but is heavy for our scope. A purpose-built ~500-LOC query system is also reasonable. |
| `PipelineEventLogger` / signposts | os_signpost-backed tracing for every step | `os.Logger` + `signposter` directly. No analogue framework needed. | Trivial. |
| `WorkspaceBuilder` + `WorkspaceGraph<UpdateGraphItem<A>>` + `SingleFileWorkspaceBuilder` | Models "what to build" as a DAG of source files / modules → outputs | Our existing `PreviewSession` discovery + a small DAG over `SourceIdentifier`s. We don't need the generic `<GraphSource, WorkspaceBuildIdentifier, Destination>` flexibility — we have one target shape. | Small. We already do most of this for thunk; reuse. |
| `PreviewPreprocessingStep` (`__designTime*` rewriting) | Syntactic transform on preview source code before compile | SwiftSyntax-based rewriter we own. `PreviewsMacros` does the macro side; the preprocessing pass would mirror what `docs/reverse-engineering.md` records about the substituted thunk file. | Small-medium. Already partially implemented in `Sources/`. |
| `XOJITThunkBuilder.build(code:...)` → `.o` | Invokes swiftc to emit an object file from a thunk source | Direct `swiftc -emit-object` shell-out (or `libSwiftDriver` if we want in-process). Already in our toolbox. | Trivial. |
| `XOJITThunkBuildConfiguration` + `CompilerArguments` (+ `ResponseFile`) | Arg-string assembly + response-file handling for the swiftc invocation | Same — small util to write `@response-file.txt` and pass it as `@path` to swiftc. | Trivial. |
| `PreviewsJITLinkerParameters` (object paths, archs, install name, load commands, rpaths, linker flags) | Serialized JIT-link invocation handed to the agent | LLVM ORC `LLJIT` + `ObjectLinkingLayer` configured with our process's symbol table as the resolver. `loadCommands` / `installName` map onto ORC's `MaterializationUnit` + Mach-O platform setup. **This is the load-bearing experiment for W2.** | **Large.** This is the unknown. JITLink Swift coverage gaps (TLVs, async funcs, witness tables, metadata registration) are the gating risk per the prompt. |
| `LinkerArgumentIngestor` / `LinkerArguments` / response-file parsing | Reads the stable-build linker command line, normalizes it, reshapes for JIT | Custom: parse the linker invocation `xcodebuild` / Bazel emits, strip non-JIT args (`-bundle_loader`, `-Xlinker -final_output`, etc.), translate the rest into ORC config. Most public-tool linker arg formats are documented. | Medium. Format diversity (ld, ld64, ldd) and Swift driver pass-through is the real cost. |
| `MachOParsing` (LinkerData, MachObject, LoadCommand, MachOFileIsLLVMBitcode) | Reads Mach-O object/binary metadata host-side | `MachO.framework` / `<mach-o/loader.h>` directly, or `LLVM.Object` / `LLVM.MC`. Public APIs are stable. | Small. |
| `DylibPreviewRecipe` + `DylibBuildConfiguration` (legacy `@_dynamicReplacement`) | swiftc → ld → codesign → standalone `.dylib` | Already in PreviewsMCP's `Sources/` (this is exactly the thunk path, per `thunk-architecture.md`). No new analogue needed. | n/a — already implemented. |
| `PreviewProduct.RuntimeLinked` (object code + descriptors, no path) | The XOJIT "ship object code, link at the agent" payload | An equivalent `enum PreviewMCPProduct { case prelinked(URL); case objectOnly(paths:[URL], descriptors: ...) }`. Conceptually trivial; just our build's output type. | Trivial. |
| `BuildProductsCache` (incremental product cache) | Per-`SourceIdentifier` cached `.o` / `.dylib`, diff-driven invalidation | Hash-keyed cache over `(SourceIdentifier, build settings hash)` → product path. Same shape; matches our file-watcher invalidation work. | Small. |
| `PreviewBuildDiff` + `SourcedIncrementalUpdate` (small/middle/large tiering) | Classifies edits to drive the right rebuild tier | Reuse `LiteralRegionClassifier` (already in `Sources/`) for the small (literal) tier; structural diff via SwiftSyntax for middle; full rebuild for large. | Small — already partially implemented. |
| `PreviewUpdatePlan.AgentRecord.JITLinkDescription` (subgraph sent to agent) | Set of graph nodes whose objects need re-linking this tick | Plain `[ObjectFileURL]` + a "new install name" string. Same content, simpler shape — we have one agent flavor. | Trivial. |
| `PreviewUpdater` protocol (host-side handle: update, applyIncrementalUpdates, kill, teardown, relinquish) | Host's IPC façade to a running agent | Our own protocol over Unix-domain socket or XPC: `update(execPoint, products, incrementals) async throws`. Wire format is ours to define. | Small (modulo iOS-host-app wire-protocol research). |
| `PreviewUpdaterStore` + `PurgeStrategy` + `PreviewUpdaterLimit` | Pool / cap on concurrent agents; reuse policy | Same shape: an actor that maps `Key -> AgentHandle`, evicts on LRU or explicit purge. | Trivial. |
| `PreviewAgentBundle` (incl. `runMode: .dynamicReplacement|.jitExecutor|.fullBinary`) + `PreviewDeviceAgentInstaller` | The on-device bundle + installer | Our own host-app bundle + `Virtualization`-based installer for VM; xcrun simctl/devicectl for real devices. The `runMode` flag becomes "which JIT runtime variant the bundle launches with." | Medium (host-app side; separate stream). |
| `PreviewService` (top-level façade: register data sources, set needs update, observe events) | Xcode's entry point into the whole machine | Our top-level `PreviewsMCP.Server` actor. Same shape; method set is essentially {register-source, request-update, observe-events}. | Small. |
| `PreviewRecipeGenerator` / `PreviewRecipeGroup` | Factory: turn an `AgentRecord.SourceFileRecord` + translation unit into a concrete recipe | Direct switch on diff tier → concrete builder closure. We don't need protocol-based generators because we have one recipe per tier. | Trivial. |
| `RegistryLocationMap` / `RegistryPreviewDefinition` / `RegistryPreviewInstance` | Resolves `#Preview` macro registrations to source locations at runtime | We already control the macro (`libPreviewsMacros.dylib` analogue). Map: `RegistryID -> (source file, line, preview name)`. | Trivial. |
| `RunDestination` family + `DestinationCapabilitiesCache` | "Where does this preview run" (macOS, sim, device) + caps negotiation | Our own enum + capability struct. Same shape, much smaller since our destination set is constrained. | Trivial. |
| `ExecutionPoint` protocol family (Preview / Provider / Preflight / Registry / CFunction / Scheduled) | "What's being executed" — a `#Preview` body, a `PreviewProvider`, a preflight check, etc. | A single enum `ExecutionPoint` with associated values is enough for our scope; we don't ship the Registry / Preflight / CFunction variants. | Trivial. |
| `InjectionFramework` (path to `PreviewsInjection.framework`) | `DYLD_INSERT_LIBRARIES`-injected runtime | Our own `libPreviewsMCPInjection.dylib` (or static-link the runtime into the agent). This is the runtime side of W3's patch-point set. | **Large (separate workstream W3).** Patch-point selection is the LT-2 uncertainty. |
| `CodeGenerationIntelligence.CompilationResult` (return of `PreviewService.compile`) | LLM-assisted code completion / repair? | Out of scope. We don't need to replicate this; it appears to be an Xcode-Intelligence sidecar feature, not core to the JIT path. | n/a. |
| `usingPipelineV2: Bool` flag threaded through `ExecutionPoint.update` | Apple is mid-migration to a v2 pipeline internally | Note for forward-compat. No analogue work; just a marker that Apple's internal shape is in flux, reinforcing the "build our own on stable layers" thesis. | n/a. |

**Summary of effort distribution:** the small/trivial rows dominate. The two large rows are
(a) the LLVM ORC JITLink integration with Swift `.o` emission (W2's POC — the single
load-bearing public-layer experiment) and (b) the patch-point set delivered as a runtime
injection (W3 — orthogonal). Everything else is mechanical reshaping of data structures.

---

## 4. Open questions (and which data source resolves each)

The export dump tells us **types and method signatures**. It tells us **nothing** about
inter-step wire formats, runtime sequencing, what actually triggers re-execution, or the byte
layout of artifacts. The following need other data sources:

1. **Are "WorkCollectionStep…PerformUpdateStep" really `PipelineEventSignpost` names?**
   - Next data source: `log stream --predicate 'subsystem == "com.apple.PreviewsPipeline"'`
     during a real preview session in the VM. Cross-reference signpost names against the
     guesses in Section 2's table.
   - Alternative: `dtrace -n 'pid$target::*signpost*:entry { ... }' -p $XCODE_PID`.

2. **Exact graph-node firing order during one update tick.**
   - Next data source: dtrace on `PreviewsPipeline` Swift methods. Specifically probe
     `*ResourceGraph*invalidate*`, `*UpdateQueueGroup*trigger*`, `*PreviewUpdateSession*requests*`.
     Print stacks; reconstruct the actual call sequence per signpost.

3. **What triggers a re-build vs a re-link vs a re-execute?**
   - We have `PreviewBuildDiff.Discriminant` (small/middle/large hint), but the exact
     discriminator logic is not visible from exports. Class-dump of `PreviewBuildDiff` and
     `BuildProductsCache.apply(_:forTranslationUnitIdentifiedBy:)` would expose the
     decision tree.
   - Next data source: `class-dump-swift` on `PreviewsPipeline.framework` (recovers the
     private nominal type field layouts the exports don't show).

4. **Byte-level shape of `PreviewsJITLinkerParameters` over the wire.**
   - We know the fields; we don't know how it's serialized to the agent. Could be
     `Codable` to JSON, `NSKeyedArchiver`, or a custom binary.
   - Next data source: lldb attach, set a breakpoint on the dispatch thunk for
     `PreviewUpdater.update(...)`, dump the `ProductLoadingParameters` and any encoded
     payload as it crosses to the agent. Combined with dtrace on `write()` to the agent
     socket (per `docs/reverse-engineering.md:188-209`), we should reconstruct the framing.

5. **What does `PreviewProduct.PreLinked.LinkingStrategy` /
   `.LoadingStrategy` / `.ExternalFunctionBinding` enumerate?**
   - Exports tell us they're hashable/equatable enums; not the case names. Likely
     `.full | .interposed | .stub`-style alternatives.
   - Next data source: `class-dump-swift` for nominal type descriptors with case names; or
     lldb `expr -- print(strategy)` against a live process.

6. **Does the agent's JIT linker actually use LLVM ORC, or a private fork?**
   - **Closed.** YES — Apple's `XOJITExecutor.framework` is built on LLVM ORC + JITLink,
     statically linked behind a Swift+XPC façade. See
     `research/scripts/analysis/q6-jit-runtime-findings.md` for the full evidence trail.

7. **`PreviewAgentRunMode.fullBinary` — what is the "full binary" mode?**
   - **Closed by W3.** Corresponds to the **framework-agent path** of
     `XCPreviewAgent` — the agent boots into a stock `NSApplicationMain` →
     `AppDelegate` → `CFRunLoopRun` and sits idle. Used when neither the Dylib
     path (link-time `__TEXT,__debug_dylib` sections populated) nor the JIT path
     (PreviewsInjection.framework injected via `DYLD_INSERT_LIBRARIES`) is
     active. See `research/scripts/analysis/w3-lifecycle-timeline.md` Step 6.

8. **`VerifyThunkPresenceBuildStep` — what gets verified?**
   - No matching Swift symbol. Possibly a `ResourceGraph` query that ensures every required
     thunk is present in `BuildProductsCache` before the agent is asked to launch. Could also
     be a Mach-O sanity check (signature verification?).
   - Next data source: signpost capture (Q1) to confirm the name actually exists at runtime,
     then dtrace stack on its `PipelineEventLogger.startEvent(...)` callsite.

9. **What does Apple's `JITLinkDescription` actually contain that we'd need to mirror?**
   - We see only `nodes: OrderedIdentifiedSet<...Node>`. The Node payloads (`UpdateGraphItem`)
     carry `buildable`, `sourceFile`, `executionPointPack`, `executionPointSource`. Whether
     the description carries pre-resolved object file paths or symbolic node refs is unclear.
   - Next data source: lldb breakpoint on `jitLinkDescription.getter`; dump the contents.

10. **What's `usingPipelineV2`?**
    - Threaded as a `Bool` through `ExecutionPoint.update(...)`. Means Apple's internal
      pipeline has a v2 shape gated behind a flag. Knowing what changes between v1 and v2
      would inform whether we're studying a stable target or one mid-migration.
    - Next data source: enumerate all symbols matching `*v2*` / `*PipelineV2*` in the full
      Xcode shared-frameworks set (not just `PreviewsPipeline`); look for parallel type
      hierarchies. `dyld_info -exports` across the 12 sibling frameworks.

11. **Where does `CodeGenerationIntelligence.CompilationResult` originate?**
    - Out-of-scope for this spike, but worth a one-line follow-up: if Xcode's preview
      pipeline gained an LLM-assisted compile step (probably for auto-fixing preview-breaking
      edits), it implies non-trivial coupling between previews and Xcode Intelligence. Confirm
      it's optional and not on the critical path.
    - Next data source: `dyld_info -exports` on `CodeGenerationIntelligence.framework`;
      check whether `PreviewService.compile` is called on the hot path or only error-recovery.

12. **The "12 sibling frameworks" (host-side) cross-coupling map.**
    - We've focused on `PreviewsPipeline`. The other 11 (`PreviewsModel`,
      `PreviewsFoundationHost`, `PreviewsMessagingHost`, …) each contribute types referenced
      from this dump (`PreviewsModel.Module`, `PreviewsMessagingHost.PreviewIncrementalUpdate`,
      `PreviewsFoundationHost.Future`, `PreviewsFoundationHost.Query`, …). For each, we need
      at minimum the public API surface to know which types are wire types vs internal.
    - Next data source: `dyld_info -exports` + `class-dump-swift` on each of the 12, captured
      into `research/scripts/data/<framework>-exports.txt`. Already partially scoped per
      `dump-previews-pipeline-exports.sh`.

13. **Concurrent-patching semantics (LT-2 territory).**
    - **Partially closed by W3.** The patch mechanism is identified (in-place
      `mprotect`+`memcpy` driven by host-side ORC via XOJITExecutor's
      `___xojit_executor_write_mem` remote-EPC primitive), the serialization
      model is inferred (main-thread marshaling + atomic pointer-width
      writes), but the actual call-versus-patch race window has not been
      observed under load. See
      `research/scripts/analysis/w3-patch-point-set.md` §4. Full close
      requires the pre-implementation runtime-confirmation dtrace plan
      described there.

---

## Appendix — data-source provenance

- All claims about specific symbol names are grounded in
  `research/scripts/data/previews-pipeline-exports.txt`. Specific addresses are omitted from
  this draft to keep it readable; grep against the dump to verify any individual claim.
- Where this draft says "enum case …", the evidence is an export of the form
  `enum case for PreviewsPipeline.<Type>.<case>(<Type>.Type) -> ...`.
- Where this draft says "protocol", the evidence is a `protocol descriptor for ...` export
  plus matching `method descriptor for ...` lines.
- Where this draft cites an `init(...)` signature, the evidence is the demangled
  initializer name plus its `default argument N of ...` entries.
