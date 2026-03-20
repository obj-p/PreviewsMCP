import Foundation
import SwiftParser
import SwiftSyntax

/// Information about a single `#Preview` block found in a Swift source file.
public struct PreviewInfo: Sendable {
    /// Optional display name from `#Preview("Name") { ... }`.
    public let name: String?
    /// The raw source text of the closure body (the code inside the `{ ... }`).
    public let closureBody: String
    /// Location in the source file.
    public let line: Int
    public let column: Int
    /// 0-based index among all `#Preview` blocks in the file.
    public let index: Int
}

/// Parses Swift source files to find `#Preview` macro invocations.
public enum PreviewParser {

    /// Parse a Swift source file and return all `#Preview` blocks found.
    public static func parse(source: String) -> [PreviewInfo] {
        let sourceFile = Parser.parse(source: source)
        let visitor = PreviewVisitor(viewMode: .sourceAccurate)
        visitor.walk(sourceFile)
        return visitor.previews
    }

    /// Parse a Swift source file at the given path.
    public static func parse(fileAt path: URL) throws -> [PreviewInfo] {
        let source = try String(contentsOf: path, encoding: .utf8)
        return parse(source: source)
    }
}

private final class PreviewVisitor: SyntaxVisitor {
    var previews: [PreviewInfo] = []

    // SwiftParser parses file-scope #Preview as MacroExpansionExprSyntax
    override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
        guard node.macroName.text == "Preview" else {
            return .skipChildren
        }
        addPreview(
            arguments: node.arguments,
            trailingClosure: node.trailingClosure,
            node: Syntax(node)
        )
        return .skipChildren
    }

    // Some parser versions may use MacroExpansionDeclSyntax instead
    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard node.macroName.text == "Preview" else {
            return .skipChildren
        }
        addPreview(
            arguments: node.arguments,
            trailingClosure: node.trailingClosure,
            node: Syntax(node)
        )
        return .skipChildren
    }

    private func addPreview(
        arguments: LabeledExprListSyntax,
        trailingClosure: ClosureExprSyntax?,
        node: Syntax
    ) {
        guard let closure = trailingClosure else { return }

        let name = extractName(from: arguments)
        let closureBody = closure.statements.description.trimmed

        let location = node.startLocation(
            converter: SourceLocationConverter(
                fileName: "",
                tree: node.root
            ))

        let info = PreviewInfo(
            name: name,
            closureBody: closureBody,
            line: location.line,
            column: location.column,
            index: previews.count
        )
        previews.append(info)
    }

    private func extractName(from arguments: LabeledExprListSyntax) -> String? {
        guard let firstArg = arguments.first,
            let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self)
        else {
            return nil
        }
        return stringLiteral.segments.description
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
