import Foundation
import Testing

@testable import PreviewsCore

@Suite("Path.normalize")
struct PathTests {

    @Test("expands a leading tilde to the user's home directory")
    func expandsLeadingTilde() {
        let home = NSHomeDirectory()
        #expect(Path.normalize("~/foo") == "\(home)/foo")
        #expect(Path.normalize("~") == home)
    }

    @Test("expands ~user via getpwnam")
    func expandsNamedUserTilde() throws {
        // `~root` is the most portable named-user case on macOS — root
        // always exists and `getpwnam("root")` always resolves. The doc
        // calls out this exact case as a test scenario.
        let expanded = (("~root" as NSString).expandingTildeInPath)
        try #require(expanded != "~root", "platform did not expand ~root via getpwnam")
        #expect(Path.normalize("~root/foo") == "\(expanded)/foo")
    }

    @Test("collapses . and .. segments and absolutizes against cwd")
    func collapsesDotSegments() {
        let cwd = FileManager.default.currentDirectoryPath
        // Resolve cwd through the same normalization pipeline so the
        // expectation tolerates a symlinked working directory (common
        // on macOS where /tmp -> /private/tmp).
        let normalizedCwd = Path.normalize(cwd)
        #expect(Path.normalize("./a/../b") == "\(normalizedCwd)/b")
        #expect(Path.normalize("./b") == "\(normalizedCwd)/b")
    }

    @Test("resolves symlinks once at the boundary")
    func resolvesSymlinks() throws {
        let tmp = FileManager.default.temporaryDirectory
        let target = tmp.appendingPathComponent("normalize-target-\(UUID().uuidString)")
        let link = tmp.appendingPathComponent("normalize-link-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: target.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: link)
        }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        // The symlink itself sits under a parent that may itself be a
        // symlink (e.g., /var -> /private/var). Compare against the
        // fully-resolved target path to avoid coupling to that detail.
        let expected = target.resolvingSymlinksInPath().path
        #expect(Path.normalize(link.path) == expected)
    }

    @Test("non-existent paths are normalized lexically without erroring")
    func nonExistentPath() {
        let home = NSHomeDirectory()
        let name = "nope-\(UUID().uuidString)"
        // No file at this path; helper must not throw, must tilde-expand,
        // and must preserve the trailing component (i.e., not silently
        // drop a non-existent leaf).
        #expect(Path.normalize("~/\(name)") == "\(home)/\(name)")
    }

    @Test("empty input is returned unchanged")
    func emptyInput() {
        // Guard against `URL(fileURLWithPath: "")` producing "/" on macOS.
        #expect(Path.normalize("") == "")
    }

    @Test("absolute paths are passed through unchanged when already canonical")
    func canonicalAbsolutePath() {
        // /tmp on macOS is a symlink to /private/tmp; the helper resolves it.
        let resolved = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().path
        #expect(Path.normalize("/tmp") == resolved)
    }

    @Test("normalizeURL agrees with normalize for representative inputs")
    func normalizeURLAgreesWithNormalize() {
        // Pin the contract that the URL form is just a wrapper around the
        // String form. The empty-string edge case is excluded — `URL` has
        // no natural empty form (`URL(fileURLWithPath: "")` falls back to
        // the cwd on macOS), and no caller passes an empty string to the
        // URL helper in practice (CLI sites gate on `if let file` first).
        for raw in ["~/foo", "/tmp", "./a/../b"] {
            #expect(Path.normalizeURL(raw).path == Path.normalize(raw))
        }
    }
}
