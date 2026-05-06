import Foundation
import Testing

@testable import PreviewsCore

/// Direct fixture tests for `BuildSystemSupport`. The shared filesystem
/// helpers are now load-bearing for SPM and SetupBuilder linking; without
/// these tests, a regression in scan logic silently breaks linking with
/// no failing test (the only existing coverage was via the `SPM` /
/// `Xcode` shims for `collectGeneratedSources`).
@Suite("BuildSystemSupport")
struct BuildSystemSupportTests {

    // MARK: - collectFrameworks

    @Test("collectFrameworks returns names of .framework bundles in binPath")
    func frameworks_findsBundles() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }

        try makeFrameworkBundle(named: "Lottie", in: tmp)
        try makeFrameworkBundle(named: "FirebaseAnalytics", in: tmp)

        let names = BuildSystemSupport.collectFrameworks(binPath: tmp).sorted()
        #expect(names == ["FirebaseAnalytics", "Lottie"])
    }

    @Test("collectFrameworks ignores plain files with .framework suffix")
    func frameworks_ignoresFiles() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }

        try makeFrameworkBundle(named: "Real", in: tmp)
        // A regular file named like a framework — must not be reported.
        try "not a bundle".write(
            to: tmp.appendingPathComponent("Fake.framework"),
            atomically: true,
            encoding: .utf8
        )

        #expect(BuildSystemSupport.collectFrameworks(binPath: tmp) == ["Real"])
    }

    @Test("collectFrameworks ignores entries without .framework suffix")
    func frameworks_filtersBySuffix() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }

        try makeFrameworkBundle(named: "Real", in: tmp)
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("NotAFramework"),
            withIntermediateDirectories: false
        )

        #expect(BuildSystemSupport.collectFrameworks(binPath: tmp) == ["Real"])
    }

    @Test("collectFrameworks returns empty for a nonexistent directory")
    func frameworks_missingDirectoryReturnsEmpty() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-bogus-\(UUID().uuidString)")
        #expect(BuildSystemSupport.collectFrameworks(binPath: bogus).isEmpty)
    }

    // MARK: - collectGeneratedSources

    @Test("collectGeneratedSources returns .swift files in the directory")
    func generated_findsSwiftFiles() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }

        try "// a".write(
            to: tmp.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        try "// b".write(
            to: tmp.appendingPathComponent("b.swift"), atomically: true, encoding: .utf8)

        let found = BuildSystemSupport.collectGeneratedSources(in: tmp)
            .map(\.lastPathComponent)
            .sorted()
        #expect(found == ["a.swift", "b.swift"])
    }

    @Test("collectGeneratedSources filters non-.swift files")
    func generated_filtersByExtension() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }

        try "// keep".write(
            to: tmp.appendingPathComponent("keep.swift"), atomically: true, encoding: .utf8)
        try "// header".write(
            to: tmp.appendingPathComponent("ignore.h"), atomically: true, encoding: .utf8)
        try "// no ext".write(
            to: tmp.appendingPathComponent("README"), atomically: true, encoding: .utf8)

        #expect(
            BuildSystemSupport.collectGeneratedSources(in: tmp)
                .map(\.lastPathComponent) == ["keep.swift"]
        )
    }

    @Test("collectGeneratedSources is non-recursive")
    func generated_nonRecursive() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }
        let nested = tmp.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)

        try "// shallow".write(
            to: tmp.appendingPathComponent("shallow.swift"), atomically: true, encoding: .utf8)
        try "// deep".write(
            to: nested.appendingPathComponent("deep.swift"), atomically: true, encoding: .utf8)

        let found = BuildSystemSupport.collectGeneratedSources(in: tmp)
            .map(\.lastPathComponent)
        #expect(found == ["shallow.swift"])
    }

    @Test("collectGeneratedSources returns empty for a nonexistent directory")
    func generated_missingDirectoryReturnsEmpty() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-bogus-\(UUID().uuidString)")
        #expect(BuildSystemSupport.collectGeneratedSources(in: bogus).isEmpty)
    }

    // MARK: - collectObjectFiles

    @Test("collectObjectFiles returns .o files recursively")
    func objects_recursive() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }
        let sub = tmp.appendingPathComponent("Foo.build")
        let subSub = sub.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: subSub, withIntermediateDirectories: true)

        try Data().write(to: tmp.appendingPathComponent("top.o"))
        try Data().write(to: sub.appendingPathComponent("mid.o"))
        try Data().write(to: subSub.appendingPathComponent("deep.swift.o"))

        let found = BuildSystemSupport.collectObjectFiles(in: tmp)
            .map(\.lastPathComponent)
            .sorted()
        #expect(found == ["deep.swift.o", "mid.o", "top.o"])
    }

    @Test("collectObjectFiles filters non-.o files")
    func objects_filtersByExtension() throws {
        let tmp = makeFixture()
        defer { cleanup(tmp) }

        try Data().write(to: tmp.appendingPathComponent("keep.o"))
        try "src".write(
            to: tmp.appendingPathComponent("source.swift"), atomically: true, encoding: .utf8)
        try Data().write(to: tmp.appendingPathComponent("static.a"))

        #expect(
            BuildSystemSupport.collectObjectFiles(in: tmp)
                .map(\.lastPathComponent) == ["keep.o"]
        )
    }

    @Test("collectObjectFiles returns empty for a nonexistent directory")
    func objects_missingDirectoryReturnsEmpty() {
        let bogus = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-bogus-\(UUID().uuidString)")
        #expect(BuildSystemSupport.collectObjectFiles(in: bogus).isEmpty)
    }

    // MARK: - Fixture helpers

    private func makeFixture() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-bsupport-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Build a minimal `<name>.framework` directory bundle in `parent`.
    /// `collectFrameworks` checks `.isDirectory` on the entry, so an empty
    /// directory is sufficient; we don't need an Info.plist or binary.
    private func makeFrameworkBundle(named name: String, in parent: URL) throws {
        let bundle = parent.appendingPathComponent("\(name).framework")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }
}
