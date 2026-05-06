import Foundation
import Testing

@testable import PreviewsCore

@Suite("Toolchain")
struct ToolchainTests {

    @Test("macOS SDK path resolves via --sdk macosx and ends in .sdk")
    func macOSSDKPathShape() async throws {
        Toolchain._resetCacheForTesting()
        let path = try await Toolchain.sdkPath(for: .macOS)
        #expect(path.contains("MacOSX"))
        #expect(path.hasSuffix(".sdk"))
    }

    @Test("iOS simulator SDK path resolves and ends in .sdk")
    func iOSSDKPathShape() async throws {
        Toolchain._resetCacheForTesting()
        let path = try await Toolchain.sdkPath(for: .iOS)
        #expect(path.contains("iPhoneSimulator"))
        #expect(path.hasSuffix(".sdk"))
    }

    @Test("Repeat lookups return cached value (identical string)")
    func cachesValues() async throws {
        Toolchain._resetCacheForTesting()
        let first = try await Toolchain.sdkPath(for: .macOS)
        let second = try await Toolchain.sdkPath(for: .macOS)
        #expect(first == second)
    }

    @Test("Tool lookups resolve to absolute paths")
    func toolPathsAreAbsolute() async throws {
        Toolchain._resetCacheForTesting()
        let swiftc = try await Toolchain.swiftcPath()
        let codesign = try await Toolchain.codesignPath()
        let ar = try await Toolchain.arPath()
        #expect(swiftc.hasPrefix("/"))
        #expect(codesign.hasPrefix("/"))
        #expect(ar.hasPrefix("/"))
    }

    /// Regression for issue #170: Compiler used a bare `xcrun --show-sdk-path`
    /// which on hosts with both Xcode and CommandLineTools installed could
    /// resolve to a different SDK than every other call site (which use
    /// `--sdk macosx`). Pin the invariant: Compiler's resolved SDK must
    /// equal Toolchain's macOS SDK.
    @Test("Compiler(macOS).sdkPath matches Toolchain.sdkPath(.macOS)")
    func compilerSDKMatchesToolchain() async throws {
        Toolchain._resetCacheForTesting()
        let compiler = try await Compiler(platform: .macOS)
        let toolchainSDK = try await Toolchain.sdkPath(for: .macOS)
        #expect(compiler.sdkPath == toolchainSDK)
    }

    /// Layer 2 SDK inheritance (issue #170): when the caller passes
    /// `overrideSDK`, the Compiler must use it instead of its default.
    /// We prove the override is honored by feeding a bogus SDK path and
    /// asserting that swiftc fails referencing that path — if the override
    /// were ignored, swiftc would succeed against the real SDK.
    @Test("compileCombined(overrideSDK:) routes the override to swiftc")
    func overrideSDKReachesSwiftc() async throws {
        Toolchain._resetCacheForTesting()
        let compiler = try await Compiler(platform: .macOS)
        let bogus = "/totally-not-an-sdk-\(UUID().uuidString)"
        let trivialSource = "public func _previewsmcpProbe() {}"

        do {
            _ = try await compiler.compileCombined(
                source: trivialSource,
                moduleName: "ProbeModule_\(Int.random(in: 0...999_999))",
                overrideSDK: bogus
            )
            Issue.record(
                "Expected compile to fail when overrideSDK is bogus, but it succeeded.")
        } catch let error as CompilationError {
            // swiftc surfaces the bogus path it was handed; that's our proof.
            let mentions = error.stderr.contains(bogus) || error.message.contains(bogus)
            #expect(
                mentions,
                Comment(rawValue: "Expected the bogus SDK path to appear in the "
                    + "compiler error, indicating the override reached swiftc. Got "
                    + "message=\(error.message), stderr=\(error.stderr)"))
        }
    }
}
