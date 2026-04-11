import Foundation

/// Output of a build system — everything needed to compile a preview dylib against project artifacts.
public struct BuildContext: Sendable {
    /// The module name to `import` in the bridge source (e.g., "MyApp", "MyFeatureKit").
    public let moduleName: String

    /// Additional flags to pass to swiftc (typically -I for dependency modules).
    public let compilerFlags: [String]

    /// Path to the project root (Package.swift directory, .xcodeproj parent, etc.).
    public let projectRoot: URL

    /// The target name within the project that contains the source file.
    public let targetName: String

    // MARK: - Tier 2 (optional): compile all target sources + literal hot-reload

    /// All source files in the target EXCEPT the preview file.
    /// When non-nil, PreviewSession compiles these alongside the preview file (with ThunkGenerator)
    /// into a single dylib — all types are visible and literal hot-reload works.
    public let sourceFiles: [URL]?

    /// Whether this context supports Tier 2 (source compilation with literal hot-reload).
    public var supportsTier2: Bool { sourceFiles != nil }

    // MARK: - Setup plugin (optional)

    /// Module name of the setup target (e.g., "MyAppPreviewSetup").
    public let setupModuleName: String?

    /// Additional compiler flags for the setup module (typically -I for its .swiftmodule).
    public let setupCompilerFlags: [String]

    public init(
        moduleName: String,
        compilerFlags: [String],
        projectRoot: URL,
        targetName: String,
        sourceFiles: [URL]? = nil,
        setupModuleName: String? = nil,
        setupCompilerFlags: [String] = []
    ) {
        self.moduleName = moduleName
        self.compilerFlags = compilerFlags
        self.projectRoot = projectRoot
        self.targetName = targetName
        self.sourceFiles = sourceFiles
        self.setupModuleName = setupModuleName
        self.setupCompilerFlags = setupCompilerFlags
    }
}
