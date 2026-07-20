import Foundation
@testable import PreviewsCore
import Testing

@Suite("XCFramework slice inventory")
struct XCFrameworkSlicesTests {
    private func makeXCFramework(libraries: [[String: Any]]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-xcf-\(UUID().uuidString).xcframework")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "AvailableLibraries": libraries,
            "CFBundlePackageType": "XFWK",
            "XCFrameworkFormatVersion": "1.0",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: root.appendingPathComponent("Info.plist"))
        return root
    }

    @Test("a device-only inventory has no simulator slice and lists its identifier")
    func deviceOnlyInventory() throws {
        let xcf = try makeXCFramework(libraries: [
            [
                "LibraryIdentifier": "ios-arm64",
                "SupportedPlatform": "ios",
            ],
        ])
        defer { try? FileManager.default.removeItem(at: xcf) }

        let slices = XCFrameworkSlices.slices(in: xcf)
        #expect(slices?.map(\.identifier) == ["ios-arm64"])
        #expect(slices?.contains { $0.matches(.iOS) } == false)
        #expect(slices?.contains { $0.matches(.macOS) } == false)
    }

    @Test("a simulator slice satisfies iOS; a macos slice satisfies macOS")
    func matchingSlices() throws {
        let xcf = try makeXCFramework(libraries: [
            [
                "LibraryIdentifier": "ios-arm64-simulator",
                "SupportedPlatform": "ios",
                "SupportedPlatformVariant": "simulator",
            ],
            [
                "LibraryIdentifier": "macos-arm64",
                "SupportedPlatform": "macos",
            ],
        ])
        defer { try? FileManager.default.removeItem(at: xcf) }

        let slices = XCFrameworkSlices.slices(in: xcf)
        #expect(slices?.contains { $0.matches(.iOS) } == true)
        #expect(slices?.contains { $0.matches(.macOS) } == true)
    }

    @Test("an unreadable bundle yields nil identifiers, degrading the enricher")
    func unreadableBundle() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-missing-\(UUID().uuidString).xcframework")

        #expect(XCFrameworkSlices.slices(in: missing) == nil)
    }
}
