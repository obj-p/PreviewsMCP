import BundleRedirect
import Foundation
import ObjectiveC
import Testing

/// The hook is process-global state, so every transition runs in one ordered
/// test: install, redirect an imageless class, leave real classes alone,
/// replace the path, clear it.
@Suite("BundleRedirect decision table", .serialized)
struct BundleRedirectTests {
    private final class RealImageToken {}

    private static let imagelessClass: AnyClass = {
        let cls = objc_allocateClassPair(NSObject.self, "PMCPImagelessProbe", 0)!
        objc_registerClassPair(cls)
        return cls
    }()

    private func makeWrapper(marker: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wrapper-\(UUID().uuidString).framework")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: dir.appendingPathComponent("marker.txt"))
        return dir
    }

    @Test("imageless classes redirect to the configured wrapper; real classes do not")
    func decisionTable() throws {
        let wrapper = try makeWrapper(marker: "first")
        defer { try? FileManager.default.removeItem(at: wrapper) }

        #expect(class_getImageName(Self.imagelessClass) == nil)
        #expect(Bundle(for: Self.imagelessClass) == Bundle.main)

        previewsmcp_set_resource_wrapper(wrapper.path)
        let redirected = Bundle(for: Self.imagelessClass)
        #expect(redirected.bundlePath == wrapper.path)
        #expect(redirected.url(forResource: "marker", withExtension: "txt") != nil)

        #expect(Bundle(for: RealImageToken.self) != redirected)
        #expect(Bundle(for: NSString.self).bundlePath.contains("Foundation.framework"))

        let replacement = try makeWrapper(marker: "second")
        defer { try? FileManager.default.removeItem(at: replacement) }
        previewsmcp_set_resource_wrapper(replacement.path)
        #expect(Bundle(for: Self.imagelessClass).bundlePath == replacement.path)

        previewsmcp_set_resource_wrapper("/nonexistent/path/App.framework")
        #expect(Bundle(for: Self.imagelessClass) == Bundle.main)

        previewsmcp_set_resource_wrapper(nil)
        #expect(Bundle(for: Self.imagelessClass) == Bundle.main)
    }
}
