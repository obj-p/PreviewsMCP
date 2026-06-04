import AppKit
import Foundation
import PreviewsCore
import PreviewsMacOS
import Testing

@testable import PreviewsEngine

@MainActor
@Suite("MacOSPreviewHandle agent snapshot")
struct MacOSPreviewHandleAgentSnapshotTests {

    final class RecordingReloader: StructuralReloader, @unchecked Sendable {
        func renderObject(
            at objectPath: URL, supportObjectPaths: [URL], archivePaths: [URL], dylibPaths: [URL],
            entrySymbol: String
        ) async throws {}
    }

    @Test func snapshotReturnsAgentImage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci3b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        struct ColorView: View {
            var body: some View {
                Color(red: 0, green: 1, blue: 0).frame(width: 8, height: 8)
            }
        }

        #Preview {
            ColorView()
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let host = PreviewHost()
        host.structuralReloader = RecordingReloader()

        let imagePath = try await host.jitStructuralReload(sessionID: "s1", session: session)
        let imageURL = try #require(imagePath)
        try Self.greenPNG().write(to: imageURL)

        let handle = MacOSPreviewHandle(id: "s1", session: session, host: host)
        let data = try await handle.snapshot(quality: 1.0)

        let rep = try #require(NSBitmapImageRep(data: data))
        let color = try #require(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )
        #expect(color.greenComponent > 0.8)
        #expect(color.redComponent < 0.2)
        #expect(color.blueComponent < 0.2)
    }

    private static func greenPNG() throws -> Data {
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )
        else {
            throw SnapshotError.encodingFailed
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.encodingFailed
        }
        return data
    }
}
