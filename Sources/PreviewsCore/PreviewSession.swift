import Foundation

/// Result of a successful preview compilation.
public struct CompileResult: Sendable {
    public let dylibPath: URL
    public let literals: [LiteralEntry]
}

/// Orchestrates the full preview pipeline: parse → generate bridge → compile → return dylib path.
public actor PreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public nonisolated let previewIndex: Int

    private let compiler: Compiler
    private var compilationResult: CompilationResult?
    private var lastOriginalSource: String?
    private var lastLiterals: [LiteralEntry]?

    public enum State: Sendable {
        case idle
        case compiling
        case compiled(URL)
        case error(String)
    }

    public private(set) var state: State = .idle

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        compiler: Compiler
    ) {
        self.id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.compiler = compiler
    }

    /// Run the full pipeline and return the compiled dylib path + literal map.
    public func compile() async throws -> CompileResult {
        state = .compiling

        do {
            let source = try String(contentsOf: sourceFile, encoding: .utf8)
            let previews = PreviewParser.parse(source: source)

            guard previewIndex < previews.count else {
                throw PreviewSessionError.previewNotFound(
                    index: previewIndex,
                    available: previews.count
                )
            }
            let preview = previews[previewIndex]

            let (combinedSource, literals) = BridgeGenerator.generateCombinedSource(
                originalSource: source,
                closureBody: preview.closureBody
            )

            let moduleName = Self.moduleName(for: sourceFile)
            let result = try await compiler.compileCombined(
                source: combinedSource,
                moduleName: moduleName
            )

            compilationResult = result
            lastOriginalSource = source
            lastLiterals = literals
            state = .compiled(result.dylibPath)

            return CompileResult(dylibPath: result.dylibPath, literals: literals)
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    /// Attempt a fast literal-only update. Returns changed literal IDs and new values,
    /// or nil if a structural recompile is needed.
    public func tryLiteralUpdate(newSource: String) -> [(id: String, newValue: LiteralValue)]? {
        guard let oldSource = lastOriginalSource else { return nil }

        switch LiteralDiffer.diff(old: oldSource, new: newSource) {
        case .literalOnly(let changes):
            lastOriginalSource = newSource
            return changes
        case .structural:
            return nil
        }
    }

    private static func moduleName(for file: URL) -> String {
        let stem = file.deletingPathExtension().lastPathComponent
        let hash = String(abs(file.path.hashValue), radix: 16).prefix(6)
        return "Preview_\(stem)_\(hash)"
    }
}

public enum PreviewSessionError: Error, CustomStringConvertible {
    case previewNotFound(index: Int, available: Int)

    public var description: String {
        switch self {
        case .previewNotFound(let index, let available):
            return "Preview index \(index) not found. File has \(available) preview(s)."
        }
    }
}
