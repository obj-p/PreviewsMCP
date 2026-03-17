import Foundation
import MCP
import PreviewsCore
import PreviewHost

/// Configures and returns an MCP server with preview tools.
func configureMCPServer() async throws -> (Server, Compiler) {
    let compiler = try await Compiler()

    let server = Server(
        name: "previews-mcp",
        version: "0.1.0",
        capabilities: .init(tools: .init(listChanged: false))
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: [
            Tool(
                name: "preview_list",
                description: "List #Preview blocks in a Swift source file",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filePath": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to a Swift source file"),
                        ]),
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: "preview_start",
                description: "Compile and launch a live SwiftUI preview window. Returns a session ID.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filePath": .object([
                            "type": .string("string"),
                            "description": .string("Absolute path to a Swift source file containing #Preview"),
                        ]),
                        "previewIndex": .object([
                            "type": .string("integer"),
                            "description": .string("0-based index of which #Preview to show (default: 0)"),
                        ]),
                        "width": .object([
                            "type": .string("integer"),
                            "description": .string("Window width in points (default: 400)"),
                        ]),
                        "height": .object([
                            "type": .string("integer"),
                            "description": .string("Window height in points (default: 600)"),
                        ]),
                    ]),
                    "required": .array([.string("filePath")]),
                ])
            ),
            Tool(
                name: "preview_snapshot",
                description: "Capture a screenshot of a running preview. Returns the image.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
            Tool(
                name: "preview_stop",
                description: "Close a preview window and clean up the session.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "sessionID": .object([
                            "type": .string("string"),
                            "description": .string("Session ID from preview_start"),
                        ]),
                    ]),
                    "required": .array([.string("sessionID")]),
                ])
            ),
        ])
    }

    await server.withMethodHandler(CallTool.self) { params in
        switch params.name {
        case "preview_list":
            return try await handlePreviewList(params: params)
        case "preview_start":
            return try await handlePreviewStart(params: params, compiler: compiler)
        case "preview_snapshot":
            return try await handlePreviewSnapshot(params: params)
        case "preview_stop":
            return try await handlePreviewStop(params: params)
        default:
            return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
    }

    return (server, compiler)
}

// MARK: - Tool Handlers

private func handlePreviewList(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let filePath) = params.arguments?["filePath"] else {
        return CallTool.Result(content: [.text("Missing filePath parameter")], isError: true)
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
    }

    let previews = try PreviewParser.parse(fileAt: fileURL)

    if previews.isEmpty {
        return CallTool.Result(content: [.text("No #Preview blocks found in \(fileURL.lastPathComponent)")])
    }

    var lines: [String] = []
    for preview in previews {
        let name = preview.name ?? "Preview"
        lines.append("[\(preview.index)] \(name) (line \(preview.line))")
    }

    return CallTool.Result(content: [.text(lines.joined(separator: "\n"))])
}

private func handlePreviewStart(params: CallTool.Parameters, compiler: Compiler) async throws -> CallTool.Result {
    guard case .string(let filePath) = params.arguments?["filePath"] else {
        return CallTool.Result(content: [.text("Missing filePath parameter")], isError: true)
    }

    let fileURL = URL(fileURLWithPath: filePath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
    }

    let previewIndex: Int
    if case .int(let n) = params.arguments?["previewIndex"] {
        previewIndex = n
    } else {
        previewIndex = 0
    }

    let width: Int
    if case .int(let n) = params.arguments?["width"] {
        width = n
    } else {
        width = 400
    }

    let height: Int
    if case .int(let n) = params.arguments?["height"] {
        height = n
    } else {
        height = 600
    }

    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: compiler
    )

    let compileResult = try await session.compile()
    let sessionID = session.id

    await MainActor.run {
        do {
            try App.host.loadPreview(
                sessionID: sessionID,
                dylibPath: compileResult.dylibPath,
                title: "Preview: \(fileURL.lastPathComponent)",
                size: NSSize(width: width, height: height)
            )
            App.host.watchFile(
                sessionID: sessionID,
                session: session,
                filePath: fileURL.path,
                compiler: compiler,
                previewIndex: previewIndex
            )
        } catch {
            fputs("MCP: Failed to load preview: \(error)\n", stderr)
        }
    }

    return CallTool.Result(content: [.text("Preview started. Session ID: \(sessionID). File is being watched for changes.")])
}

private func handlePreviewSnapshot(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    // Wait briefly for SwiftUI to finish layout
    try await Task.sleep(for: .milliseconds(300))

    let pngData: Data = try await MainActor.run {
        guard let window = App.host.window(for: sessionID) else {
            throw SnapshotError.captureFailed
        }
        return try Snapshot.capture(window: window)
    }

    let base64 = pngData.base64EncodedString()

    return CallTool.Result(content: [
        .image(data: base64, mimeType: "image/png", metadata: nil)
    ])
}

private func handlePreviewStop(params: CallTool.Parameters) async throws -> CallTool.Result {
    guard case .string(let sessionID) = params.arguments?["sessionID"] else {
        return CallTool.Result(content: [.text("Missing sessionID parameter")], isError: true)
    }

    await MainActor.run {
        App.host.closePreview(sessionID: sessionID)
    }

    return CallTool.Result(content: [.text("Preview session \(sessionID) closed.")])
}
