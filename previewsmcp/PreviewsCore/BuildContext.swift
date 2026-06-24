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

    /// System framework binaries the JIT agent must `dlopen` so a linked dependency
    /// object's symbols resolve, e.g. DeviceCheck autolinked by an Xcode-managed
    /// SwiftPM package. These resolve from the dyld shared cache by canonical path,
    /// so they are pre-resolved here rather than routed through `-framework` flags
    /// (which would also reach swiftc).
    public let frameworkPaths: [URL]

    // MARK: - Tier 2 (optional): compile all target sources + literal hot-reload

    /// All source files in the target EXCEPT the preview file.
    /// When non-nil, PreviewSession compiles these alongside the preview file (with ThunkGenerator)
    /// into a single dylib — all types are visible and literal hot-reload works.
    public let sourceFiles: [URL]?

    /// Whether this context supports Tier 2 (source compilation with literal hot-reload).
    public var supportsTier2: Bool {
        sourceFiles != nil
    }

    public init(
        moduleName: String,
        compilerFlags: [String],
        projectRoot: URL,
        targetName: String,
        frameworkPaths: [URL] = [],
        sourceFiles: [URL]? = nil
    ) {
        self.moduleName = moduleName
        self.compilerFlags = compilerFlags
        self.projectRoot = projectRoot
        self.targetName = targetName
        self.frameworkPaths = frameworkPaths
        self.sourceFiles = sourceFiles
    }
}
