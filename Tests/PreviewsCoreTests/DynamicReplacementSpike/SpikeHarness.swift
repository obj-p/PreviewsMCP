import Darwin
import Foundation

@testable import PreviewsCore

/// Test-only harness for the `@_dynamicReplacement` viability spike.
///
/// Compiles tiny "stable" + "thunk" Swift sources into dylibs using the same
/// flag set the thunk architecture standardizes on, then dlopens them and
/// hands callers raw `dlsym` access. Deliberately kept crude (inline swiftc
/// args, no abstractions) — the production compilers live in `PreviewsBuild`
/// per `prompts/modularization.md`; this harness exists only to answer the
/// per-shape viability question.
struct SpikeHarness {

    /// Stable module name. The thunk uses `<moduleName>Thunk` so it can
    /// `@_private(sourceFile:) import` the stable. Same-name compilation
    /// causes swiftc to drop the import as a self-import (empirically
    /// verified — see spike notes). This contradicts the hypothesis in
    /// `prompts/thunk-architecture.md` line 50 that same module-name is
    /// required; captured for the final doc.
    let moduleName: String
    var thunkModuleName: String { "\(moduleName)Thunk" }

    let workDir: URL

    init(moduleName: String) throws {
        self.moduleName = moduleName
        self.workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dynrepl-spike-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: workDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Compile a stable dylib + .swiftmodule. Standardized flag set:
    /// `-enable-implicit-dynamic` (every function becomes dynamically
    /// replaceable) + `-enable-private-imports` (thunk can
    /// `@_private(sourceFile:)`-import this module).
    @discardableResult
    func compileStable(source: String, sourceName: String) async throws -> URL {
        let sourcePath = workDir.appendingPathComponent(sourceName)
        try source.write(to: sourcePath, atomically: true, encoding: .utf8)
        let dylib = workDir.appendingPathComponent("lib\(moduleName).dylib")
        let swiftc = try await Toolchain.swiftcPath()
        let sdk = try await Toolchain.sdkPath(named: "macosx")
        let args = [
            "-emit-library",
            "-emit-module",
            "-module-name", moduleName,
            // `-enable-implicit-dynamic` and `-enable-private-imports` are
            // frontend-only flags; the driver requires `-Xfrontend`. This
            // is the canonical pre-Xcode-16 Previews flag set
            // (`docs/reverse-engineering.md:163-167`).
            "-Xfrontend", "-enable-implicit-dynamic",
            "-Xfrontend", "-enable-private-imports",
            "-Onone",
            "-g",
            "-sdk", sdk,
            "-o", dylib.path,
            sourcePath.path,
        ]
        try await runSwiftc(swiftc, args)
        return dylib
    }

    /// Compile a thunk dylib that links against the stable.
    ///
    /// Defaults to `<moduleName>Thunk` — see `SpikeHarness.moduleName`
    /// docstring. Tests that compile multiple thunks against the same
    /// stable (multi-cycle hot-swap) pass a distinct
    /// `thunkModuleNameOverride` per call so the dispatch-table
    /// registration is unambiguous; without that, two thunks sharing
    /// the same module + symbol names step on each other's replacement
    /// registration.
    @discardableResult
    func compileThunk(
        source: String,
        sourceName: String,
        thunkModuleNameOverride: String? = nil,
        extraArgs: [String] = []
    ) async throws -> URL {
        let sourcePath = workDir.appendingPathComponent(sourceName)
        try source.write(to: sourcePath, atomically: true, encoding: .utf8)
        let dylib = workDir.appendingPathComponent(
            "libThunk_\(UUID().uuidString.prefix(8)).dylib")
        let swiftc = try await Toolchain.swiftcPath()
        let sdk = try await Toolchain.sdkPath(named: "macosx")
        let resolvedThunkModuleName = thunkModuleNameOverride ?? thunkModuleName
        let args =
            [
                "-emit-library",
                "-module-name", resolvedThunkModuleName,
                "-Onone",
                "-g",
                "-sdk", sdk,
                "-I", workDir.path,
                "-L", workDir.path,
                "-l\(moduleName)",
                "-Xlinker", "-rpath", "-Xlinker", workDir.path,
                "-o", dylib.path,
                sourcePath.path,
            ] + extraArgs
        try await runSwiftc(swiftc, args)
        return dylib
    }

    func dlopenStrict(_ dylib: URL) throws -> UnsafeMutableRawPointer {
        guard let handle = dlopen(dylib.path, RTLD_NOW | RTLD_GLOBAL) else {
            let msg = dlerror().map { String(cString: $0) } ?? "unknown"
            throw SpikeError.dlopenFailed(path: dylib.path, message: msg)
        }
        return handle
    }

    /// Look up a symbol and cast it to the caller-specified C function type.
    func dlsymOrFail<T>(
        _ handle: UnsafeMutableRawPointer,
        _ name: String,
        as: T.Type
    ) throws -> T {
        guard let sym = dlsym(handle, name) else {
            let msg = dlerror().map { String(cString: $0) } ?? "unknown"
            throw SpikeError.dlsymFailed(name: name, message: msg)
        }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Run swiftc and surface stderr on failure. Synchronous Process — async
    /// boundary kept at the awaited swiftc path lookup, not the subprocess
    /// itself (swiftc invocations here are sub-second).
    private func runSwiftc(_ exe: String, _ args: [String]) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let err =
                String(
                    data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
            let out =
                String(
                    data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8) ?? ""
            throw SpikeError.compileFailed(
                stderr: err, stdout: out, args: args)
        }
    }
}

enum SpikeError: Error, CustomStringConvertible {
    case compileFailed(stderr: String, stdout: String, args: [String])
    case dlopenFailed(path: String, message: String)
    case dlsymFailed(name: String, message: String)

    var description: String {
        switch self {
        case .compileFailed(let stderr, let stdout, let args):
            return """
                swiftc failed
                  args: \(args.joined(separator: " "))
                  stderr: \(stderr)
                  stdout: \(stdout)
                """
        case .dlopenFailed(let path, let msg):
            return "dlopen(\(path)) failed: \(msg)"
        case .dlsymFailed(let name, let msg):
            return "dlsym(\(name)) failed: \(msg)"
        }
    }
}
