import Foundation

/// Answers "which targets of this project compile this file" from the project
/// file itself, before any build runs. Classic targets list per-file
/// PBXBuildFile references; Xcode 16 filesystem-synchronized groups list no
/// files, so membership there is folder containment minus the group's
/// exception sets.
enum XcodeProjectMembership {
    struct TargetMembership: Equatable {
        let targetName: String
        let productType: String?
    }

    /// Targets in a .xcodeproj that compile the given source file.
    static func targets(
        compiling sourceFile: URL, inProject projectFile: URL
    ) throws -> [TargetMembership] {
        let pbxprojURL = projectFile.appendingPathComponent("project.pbxproj")
        let data = try Data(contentsOf: pbxprojURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard
            let root = plist as? [String: Any],
            let objects = root["objects"] as? [String: [String: Any]],
            let rootObjectID = root["rootObject"] as? String,
            let project = objects[rootObjectID],
            let targetIDs = project["targets"] as? [String]
        else {
            throw BuildSystemError.missingArtifacts(
                "Could not parse \(pbxprojURL.path)"
            )
        }

        var projectDir = projectFile.deletingLastPathComponent()
        if let projectDirPath = project["projectDirPath"] as? String, !projectDirPath.isEmpty {
            projectDir = URL(fileURLWithPath: projectDirPath, relativeTo: projectDir)
        }

        let filePaths = resolveFilePaths(
            objects: objects,
            groupID: project["mainGroup"] as? String,
            projectDir: projectDir
        )
        let filePath = sourceFile.standardizedFileURL.path

        var memberships: [TargetMembership] = []
        for targetID in targetIDs {
            guard
                let target = objects[targetID],
                let targetName = target["name"] as? String
            else { continue }
            let member =
                compilesViaSourcesPhase(
                    target: target, objects: objects, filePaths: filePaths, filePath: filePath
                )
                || compilesViaSynchronizedGroup(
                    targetID: targetID, target: target, objects: objects,
                    filePaths: filePaths, filePath: filePath
                )
            if member {
                memberships.append(
                    TargetMembership(
                        targetName: targetName,
                        productType: target["productType"] as? String
                    )
                )
            }
        }
        return memberships
    }

    /// Projects referenced by a .xcworkspace (FileRef/Group locations in
    /// contents.xcworkspacedata).
    static func projects(inWorkspace workspaceFile: URL) -> [URL] {
        let contentsURL = workspaceFile.appendingPathComponent("contents.xcworkspacedata")
        guard let data = try? Data(contentsOf: contentsURL) else { return [] }
        let parser = WorkspaceContentsParser(baseDir: workspaceFile.deletingLastPathComponent())
        return parser.parse(data: data)
    }

    // MARK: - Classic membership (PBXBuildFile)

    private static func compilesViaSourcesPhase(
        target: [String: Any],
        objects: [String: [String: Any]],
        filePaths: [String: String],
        filePath: String
    ) -> Bool {
        guard let phaseIDs = target["buildPhases"] as? [String] else { return false }
        for phaseID in phaseIDs {
            guard
                let phase = objects[phaseID],
                phase["isa"] as? String == "PBXSourcesBuildPhase",
                let buildFileIDs = phase["files"] as? [String]
            else { continue }
            for buildFileID in buildFileIDs {
                guard
                    let buildFile = objects[buildFileID],
                    let fileRefID = buildFile["fileRef"] as? String,
                    let refPath = filePaths[fileRefID]
                else { continue }
                if refPath == filePath {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Synchronized-group membership (Xcode 16+)

    private static func compilesViaSynchronizedGroup(
        targetID: String,
        target: [String: Any],
        objects: [String: [String: Any]],
        filePaths: [String: String],
        filePath: String
    ) -> Bool {
        guard let groupIDs = target["fileSystemSynchronizedGroups"] as? [String] else {
            return false
        }
        for groupID in groupIDs {
            guard
                let groupDir = filePaths[groupID],
                filePath.hasPrefix(groupDir + "/")
            else { continue }
            let relativePath = String(filePath.dropFirst(groupDir.count + 1))
            if isMembershipException(
                relativePath: relativePath, groupID: groupID,
                forTarget: targetID, objects: objects
            ) {
                continue
            }
            return true
        }
        return false
    }

    private static func isMembershipException(
        relativePath: String,
        groupID: String,
        forTarget targetID: String,
        objects: [String: [String: Any]]
    ) -> Bool {
        guard
            let group = objects[groupID],
            let exceptionIDs = group["exceptions"] as? [String]
        else { return false }
        for exceptionID in exceptionIDs {
            guard
                let exceptionSet = objects[exceptionID],
                exceptionSet["target"] as? String == targetID,
                let exceptions = exceptionSet["membershipExceptions"] as? [String]
            else { continue }
            if exceptions.contains(relativePath) {
                return true
            }
        }
        return false
    }

    // MARK: - Group-tree path resolution

    /// Absolute paths for every file reference and synchronized root group,
    /// keyed by object ID. sourceTree "<group>" is parent-relative,
    /// "SOURCE_ROOT" is project-dir-relative, "<absolute>" stands alone;
    /// build-product trees are not source files and resolve to nothing.
    private static func resolveFilePaths(
        objects: [String: [String: Any]],
        groupID: String?,
        projectDir: URL
    ) -> [String: String] {
        var paths: [String: String] = [:]
        guard let groupID else { return paths }
        var visited: Set<String> = []

        func visit(objectID: String, parentDir: URL) {
            guard visited.insert(objectID).inserted else { return }
            guard let object = objects[objectID] else { return }
            let path = object["path"] as? String
            let sourceTree = object["sourceTree"] as? String ?? "<group>"

            let base: URL? =
                switch sourceTree {
                case "<group>": parentDir
                case "SOURCE_ROOT": projectDir
                case "<absolute>": URL(fileURLWithPath: "/")
                default: nil
                }
            guard let base else { return }
            let resolved =
                path.map { base.appendingPathComponent($0).standardizedFileURL } ?? parentDir

            switch object["isa"] as? String {
            case "PBXFileReference", "PBXFileSystemSynchronizedRootGroup":
                paths[objectID] = resolved.path
            default:
                break
            }
            if let children = object["children"] as? [String] {
                for child in children {
                    visit(objectID: child, parentDir: resolved)
                }
            }
        }

        visit(objectID: groupID, parentDir: projectDir.standardizedFileURL)
        return paths
    }
}

/// Pulls .xcodeproj references out of contents.xcworkspacedata, accumulating
/// nested Group locations.
private final class WorkspaceContentsParser: NSObject, XMLParserDelegate {
    private let baseDir: URL
    private var groupStack: [URL] = []
    private var projects: [URL] = []

    init(baseDir: URL) {
        self.baseDir = baseDir
    }

    func parse(data: Data) -> [URL] {
        groupStack = [baseDir]
        projects = []
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return projects
    }

    private func resolve(location: String) -> URL? {
        let parts = location.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let (scheme, path) = (parts[0], parts[1])
        switch scheme {
        case "group":
            return (groupStack.last ?? baseDir).appendingPathComponent(path).standardizedFileURL
        case "container", "self":
            return baseDir.appendingPathComponent(path).standardizedFileURL
        case "absolute":
            return URL(fileURLWithPath: path).standardizedFileURL
        default:
            return nil
        }
    }

    func parser(
        _: XMLParser, didStartElement elementName: String,
        namespaceURI _: String?, qualifiedName _: String?,
        attributes: [String: String]
    ) {
        let location = attributes["location"].flatMap(resolve(location:))
        switch elementName {
        case "Group":
            groupStack.append(location ?? groupStack.last ?? baseDir)
        case "FileRef":
            if let location, location.pathExtension == "xcodeproj" {
                projects.append(location)
            }
        default:
            break
        }
    }

    func parser(
        _: XMLParser, didEndElement elementName: String,
        namespaceURI _: String?, qualifiedName _: String?
    ) {
        if elementName == "Group" {
            groupStack.removeLast()
        }
    }
}
