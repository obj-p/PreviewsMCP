import Foundation

/// Shared filesystem helpers used by every build-system integration plus
/// `SetupBuilder`. Each implementation (SPM, Xcode, Bazel, SetupBuilder)
/// previously open-coded these scans; pulling them into one namespace gives a
/// single definition that's easy to test and harder to drift.
///
/// The helpers here are intentionally narrow: they do filesystem reads and
/// nothing else. Subprocess execution, `.swiftmodule` existence checks, and
/// error wrapping stay in the concrete build systems because each has its own
/// load-bearing diagnostic shape (e.g., `BazelBuildSystem.runBazel`'s
/// multi-line error format covers a real CI flake — see comment there).
enum BuildSystemSupport {
    /// Names of `.framework` bundles directly under `binPath`.
    ///
    /// SPM copies pre-built `.framework` bundles (from `binaryTarget` /
    /// XCFramework deps) into the bin directory; the setup builder ships its
    /// own dylib alongside the same bundles. Both need the names to construct
    /// `-F` / `-framework` flags. The scan is shallow on purpose — `.framework`
    /// bundles only ever sit at the top level of `binPath`.
    static func collectFrameworks(binPath: URL) -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: binPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var frameworks: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".framework") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            frameworks.append(String(name.dropLast(".framework".count)))
        }
        return frameworks
    }

    /// Standardized URLs of every `.swift` file directly inside
    /// `derivedSourcesDir`. Caller is responsible for computing that directory
    /// (SPM uses `<binPath>/<Target>.build/DerivedSources/`; Xcode uses
    /// `<DERIVED_FILE_DIR>/DerivedSources/`). The scan is intentionally
    /// non-recursive and unfiltered by filename — both build systems have
    /// renamed their generated files across releases, so a whitelist would
    /// silently drop new ones.
    static func collectGeneratedSources(in derivedSourcesDir: URL) -> [URL] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: derivedSourcesDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        return
            entries
            .filter { $0.pathExtension == "swift" }
            .map { $0.standardizedFileURL }
    }

    /// Verify that `<modulesDir>/<moduleName>.swiftmodule` exists; if
    /// missing, throw the error returned by `onMissing()`. SPM,
    /// SetupBuilder, and Bazel all do this exact "build path →
    /// fileExists → throw" check after their own build subprocess
    /// finishes, with different concrete error types
    /// (`BuildSystemError.missingArtifacts` vs
    /// `SetupBuilderError.moduleNotFound`). The closure pattern lets
    /// each caller throw its own type without forcing a single error
    /// shape on all of them.
    ///
    /// Xcode's "verify build outputs" check is structurally different
    /// (it looks at `BUILT_PRODUCTS_DIR`, not a specific module file)
    /// and is intentionally NOT routed through this helper.
    static func verifySwiftModule(
        named moduleName: String,
        in modulesDir: URL,
        onMissing makeError: () -> Error
    ) throws {
        let swiftmodule = modulesDir.appendingPathComponent("\(moduleName).swiftmodule")
        guard FileManager.default.fileExists(atPath: swiftmodule.path) else {
            throw makeError()
        }
    }

    /// Recursively collect `.o` files under `directory`. Used by SPM (per
    /// dependency-target archive) and the setup builder (single dylib link).
    /// `swift build` emits Swift object files as `<Source>.swift.o`, so
    /// matching by `pathExtension == "o"` covers both C and Swift outputs.
    static func collectObjectFiles(in directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "o" {
            files.append(url)
        }
        return files
    }
}
