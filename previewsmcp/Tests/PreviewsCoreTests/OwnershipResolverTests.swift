import Foundation
@testable import PreviewsCore
import Testing

private struct FakeResolver: OwnershipResolving {
    let kind: BuildSystemKind
    let verdicts: [String: OwnershipVerdict]

    func candidateMarker(in directory: URL) -> URL? {
        verdicts[directory.path] != nil
            ? directory.appendingPathComponent("marker") : nil
    }

    func owner(
        of _: URL, at candidateRoot: URL, scheme _: String?
    ) async -> OwnershipVerdict {
        verdicts[candidateRoot.path] ?? .notMember(reason: "fake")
    }
}

@Suite("OwnershipWalk")
struct OwnershipWalkTests {
    private func tempTree(_ relativeFile: String) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ownership-\(UUID().uuidString)")
            .standardizedFileURL
        let file = root.appendingPathComponent(relativeFile)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "import SwiftUI".write(to: file, atomically: true, encoding: .utf8)
        return (root, file)
    }

    @Test("nearest confirming root beats a farther confirming root")
    func nearestConfirmingWins() async throws {
        let (root, file) = try tempTree("Nested/Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")

        let outer = FakeResolver(
            kind: .spm,
            verdicts: [root.path: .confirmed(Ownership(kind: .spm, projectRoot: root))]
        )
        let inner = FakeResolver(
            kind: .xcode,
            verdicts: [nested.path: .confirmed(Ownership(kind: .xcode, projectRoot: nested))]
        )

        let walk = OwnershipWalk(resolvers: [outer, inner])
        let ownership = try await walk.resolve(sourceFile: file, scheme: nil)
        #expect(ownership?.kind == .xcode)
        #expect(ownership?.projectRoot.path == nested.path)
    }

    @Test("a declining nearer marker does not stop a farther root from confirming")
    func declineFallsOutward() async throws {
        let (root, file) = try tempTree("Nested/Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")

        let resolver = FakeResolver(
            kind: .spm,
            verdicts: [
                nested.path: .notMember(reason: "not in any target"),
                root.path: .confirmed(Ownership(kind: .spm, projectRoot: root)),
            ]
        )

        let walk = OwnershipWalk(resolvers: [resolver])
        let ownership = try await walk.resolve(sourceFile: file, scheme: nil)
        #expect(ownership?.projectRoot.path == root.path)
    }

    @Test("an indeterminate nearer marker blocks farther candidates")
    func indeterminateBlocks() async throws {
        let (root, file) = try tempTree("Nested/Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")

        let broken = FakeResolver(
            kind: .xcode,
            verdicts: [nested.path: .indeterminate(reason: "unparseable project")]
        )
        let outer = FakeResolver(
            kind: .spm,
            verdicts: [root.path: .confirmed(Ownership(kind: .spm, projectRoot: root))]
        )

        let walk = OwnershipWalk(resolvers: [outer, broken])
        await #expect(throws: OwnershipError.self) {
            try await walk.resolve(sourceFile: file, scheme: nil)
        }
    }

    @Test("same-level tie-break follows resolver order")
    func sameLevelTieBreak() async throws {
        let (root, file) = try tempTree("Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }

        let spm = FakeResolver(
            kind: .spm,
            verdicts: [root.path: .confirmed(Ownership(kind: .spm, projectRoot: root))]
        )
        let bazel = FakeResolver(
            kind: .bazel,
            verdicts: [root.path: .confirmed(Ownership(kind: .bazel, projectRoot: root))]
        )

        let walk = OwnershipWalk(resolvers: [spm, bazel])
        let ownership = try await walk.resolve(sourceFile: file, scheme: nil)
        #expect(ownership?.kind == .spm)
    }

    @Test("no markers anywhere resolves to nil (standalone)")
    func noMarkersIsNil() async throws {
        let (root, file) = try tempTree("Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }

        let walk = OwnershipWalk(resolvers: [FakeResolver(kind: .spm, verdicts: [:])])
        let ownership = try await walk.resolve(sourceFile: file, scheme: nil)
        #expect(ownership == nil)
    }

    @Test("markers that all decline fail with every decline listed")
    func declinesAreCollected() async throws {
        let (root, file) = try tempTree("Nested/Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")

        let resolver = FakeResolver(
            kind: .spm,
            verdicts: [
                nested.path: .notMember(reason: "inner says no"),
                root.path: .notMember(reason: "outer says no"),
            ]
        )

        let walk = OwnershipWalk(resolvers: [resolver])
        do {
            _ = try await walk.resolve(sourceFile: file, scheme: nil)
            Issue.record("expected noOwner")
        } catch let error as OwnershipError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("inner says no"))
            #expect(message.contains("outer says no"))
        }
    }

    @Test("an XcodeGen manifest without a generated project becomes a diagnostic")
    func xcodegenManifestDiagnosed() async throws {
        let (root, file) = try tempTree("Sources/View.swift")
        defer { try? FileManager.default.removeItem(at: root) }
        try "name: App".write(
            to: root.appendingPathComponent("project.yml"), atomically: true, encoding: .utf8
        )

        let walk = OwnershipWalk(resolvers: [])
        do {
            _ = try await walk.resolve(sourceFile: file, scheme: nil)
            Issue.record("expected noOwner")
        } catch let error as OwnershipError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("xcodegen generate"))
        }
    }
}

@Suite("XcodeProjectMembership")
struct XcodeProjectMembershipTests {
    private func writeProject(_ pbxproj: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("membership-\(UUID().uuidString)")
            .standardizedFileURL
        let projectFile = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: projectFile, withIntermediateDirectories: true)
        try pbxproj.write(
            to: projectFile.appendingPathComponent("project.pbxproj"),
            atomically: true, encoding: .utf8
        )
        return projectFile
    }

    @Test("classic PBXBuildFile membership names the owning target only")
    func classicMembership() throws {
        let projectFile = try writeProject(
            """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 56;
                rootObject = RO;
                objects = {
                    RO = { isa = PBXProject; mainGroup = MG; targets = (T1, T2); };
                    MG = { isa = PBXGroup; children = (G1); sourceTree = "<group>"; };
                    G1 = { isa = PBXGroup; children = (F1, F2); path = Sources; sourceTree = "<group>"; };
                    F1 = { isa = PBXFileReference; path = AlphaView.swift; sourceTree = "<group>"; };
                    F2 = { isa = PBXFileReference; path = BetaView.swift; sourceTree = "<group>"; };
                    T1 = { isa = PBXNativeTarget; name = Alpha; productType = "com.apple.product-type.application"; buildPhases = (P1); };
                    P1 = { isa = PBXSourcesBuildPhase; files = (B1); };
                    B1 = { isa = PBXBuildFile; fileRef = F1; };
                    T2 = { isa = PBXNativeTarget; name = Beta; productType = "com.apple.product-type.framework"; buildPhases = (P2); };
                    P2 = { isa = PBXSourcesBuildPhase; files = (B2); };
                    B2 = { isa = PBXBuildFile; fileRef = F2; };
                };
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: projectFile.deletingLastPathComponent()) }
        let root = projectFile.deletingLastPathComponent()

        let beta = try XcodeProjectMembership.targets(
            compiling: root.appendingPathComponent("Sources/BetaView.swift"),
            inProject: projectFile
        )
        #expect(beta.map(\.targetName) == ["Beta"])

        let neither = try XcodeProjectMembership.targets(
            compiling: root.appendingPathComponent("Sources/Unknown.swift"),
            inProject: projectFile
        )
        #expect(neither.isEmpty)
    }

    @Test("synchronized-group membership is folder containment minus exceptions")
    func synchronizedGroupMembership() throws {
        let projectFile = try writeProject(
            """
            // !$*UTF8*$!
            {
                archiveVersion = 1;
                objectVersion = 77;
                rootObject = RO;
                objects = {
                    RO = { isa = PBXProject; mainGroup = MG; targets = (T1); };
                    MG = { isa = PBXGroup; children = (SG); sourceTree = "<group>"; };
                    SG = { isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>"; exceptions = (EX); };
                    EX = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = T1; membershipExceptions = (Excluded.swift); };
                    T1 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; fileSystemSynchronizedGroups = (SG); };
                };
            }
            """
        )
        defer { try? FileManager.default.removeItem(at: projectFile.deletingLastPathComponent()) }
        let root = projectFile.deletingLastPathComponent()

        let member = try XcodeProjectMembership.targets(
            compiling: root.appendingPathComponent("App/View.swift"),
            inProject: projectFile
        )
        #expect(member.map(\.targetName) == ["App"])

        let excluded = try XcodeProjectMembership.targets(
            compiling: root.appendingPathComponent("App/Excluded.swift"),
            inProject: projectFile
        )
        #expect(excluded.isEmpty)

        let outside = try XcodeProjectMembership.targets(
            compiling: root.appendingPathComponent("Elsewhere/View.swift"),
            inProject: projectFile
        )
        #expect(outside.isEmpty)
    }

    @Test("workspace contents lists referenced projects, honoring nested groups")
    func workspaceProjects() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-\(UUID().uuidString)")
            .standardizedFileURL
        let workspace = root.appendingPathComponent("All.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace version = "1.0">
            <FileRef location = "group:App/App.xcodeproj"></FileRef>
            <Group location = "group:Libs" name = "Libs">
                <FileRef location = "group:Kit/Kit.xcodeproj"></FileRef>
            </Group>
        </Workspace>
        """.write(
            to: workspace.appendingPathComponent("contents.xcworkspacedata"),
            atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let projects = XcodeProjectMembership.projects(inWorkspace: workspace)
        #expect(projects.map(\.lastPathComponent) == ["App.xcodeproj", "Kit.xcodeproj"])
        #expect(projects[0].path == root.appendingPathComponent("App/App.xcodeproj").path)
        #expect(projects[1].path == root.appendingPathComponent("Libs/Kit/Kit.xcodeproj").path)
    }
}

@Suite("XcodeBuildSystem ownership")
struct XcodeOwnershipTests {
    @Test("parseBuildSettings selects the named target's section")
    func parseBuildSettingsForTarget() {
        let output = """
        Build settings for action build and target Alpha:
            PRODUCT_MODULE_NAME = Alpha
            TARGET_NAME = Alpha

        Build settings for action build and target Beta:
            PRODUCT_MODULE_NAME = Beta
            TARGET_NAME = Beta
        """
        let beta = XcodeBuildSystem.parseBuildSettings(output, target: "Beta")
        #expect(beta["TARGET_NAME"] == "Beta")

        let first = XcodeBuildSystem.parseBuildSettings(output)
        #expect(first["TARGET_NAME"] == "Alpha")

        let missing = XcodeBuildSystem.parseBuildSettings(output, target: "Gamma")
        #expect(missing["TARGET_NAME"] == "Alpha")
    }
}

@Suite("SPMBuildSystem ownership", .serialized)
struct SPMOwnershipTests {
    private func makePackage(manifest: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("spm-ownership-\(UUID().uuidString)")
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Fixture"), withIntermediateDirectories: true
        )
        try manifest.write(
            to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8
        )
        try "import Foundation".write(
            to: root.appendingPathComponent("Sources/Fixture/View.swift"),
            atomically: true, encoding: .utf8
        )
        try "import Foundation".write(
            to: root.appendingPathComponent("Sources/Fixture/Excluded.swift"),
            atomically: true, encoding: .utf8
        )
        return root
    }

    @Test("confirms via resolved sources and declines excluded files")
    func confirmsAndHonorsExclusions() async throws {
        let root = try makePackage(
            manifest: """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "Fixture",
                targets: [.target(name: "Fixture", exclude: ["Excluded.swift"])]
            )
            """
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let member = await SPMBuildSystem.confirmOwnership(
            projectRoot: root,
            sourceFile: root.appendingPathComponent("Sources/Fixture/View.swift")
        )
        guard case let .confirmed(ownership) = member else {
            Issue.record("expected confirmed, got \(member)")
            return
        }
        #expect(ownership.targetName == "Fixture")

        let excluded = await SPMBuildSystem.confirmOwnership(
            projectRoot: root,
            sourceFile: root.appendingPathComponent("Sources/Fixture/Excluded.swift")
        )
        guard case .notMember = excluded else {
            Issue.record("expected notMember, got \(excluded)")
            return
        }
    }

    @Test("a broken manifest is indeterminate, not a silent decline")
    func brokenManifestIsIndeterminate() async throws {
        let root = try makePackage(manifest: "not a manifest")
        defer { try? FileManager.default.removeItem(at: root) }

        let verdict = await SPMBuildSystem.confirmOwnership(
            projectRoot: root,
            sourceFile: root.appendingPathComponent("Sources/Fixture/View.swift")
        )
        guard case .indeterminate = verdict else {
            Issue.record("expected indeterminate, got \(verdict)")
            return
        }
    }
}
