import Foundation
import SwiftParser
import SwiftSyntax

/// Information about a single `#Preview` block or `PreviewProvider` preview found in a Swift source file.
public struct PreviewInfo: Sendable {
    /// Optional display name from `#Preview("Name") { ... }` or `.previewDisplayName("Name")`.
    public let name: String?
    /// The raw source text of the closure body (the code inside the `{ ... }`).
    public let closureBody: String
    /// Location in the source file.
    public let line: Int
    public let column: Int
    /// 0-based index among all `#Preview` blocks in the file.
    public let index: Int

    /// First line of the closure body, truncated to 80 characters.
    public var snippet: String {
        let firstLine =
            closureBody.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? closureBody
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 80 ? String(trimmed.prefix(77)) + "..." : trimmed
    }
}

/// Parses Swift source files to find `#Preview` macro invocations and `PreviewProvider` conformances.
public enum PreviewParser {

    /// Parse a Swift source file and return all `#Preview` blocks and `PreviewProvider` previews found.
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

    // MARK: - PreviewProvider support

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        guard conformsToPreviewProvider(node) else {
            return .skipChildren
        }
        guard let body = findPreviewsBody(in: node) else {
            return .skipChildren
        }

        let items = Array(body)

        // Unwrap single `return` statement
        if items.count == 1, let returnStmt = items[0].item.as(ReturnStmtSyntax.self),
            let expr = returnStmt.expression
        {
            addPreviewProviderItems(from: expr, node: Syntax(node))
        } else if items.count == 1 {
            // Single expression — check for Group or treat as one preview
            addPreviewProviderItems(from: items[0].item, node: Syntax(node))
        } else {
            // Multiple statements (@ViewBuilder) — each is a separate preview
            for item in items {
                addSingleProviderPreview(from: item.item, node: Syntax(node))
            }
        }

        return .skipChildren
    }

    /// Check if the expression is a `Group { ... }` call, and split its children.
    /// Otherwise treat it as a single preview.
    private func addPreviewProviderItems(from syntax: SyntaxProtocol, node: Syntax) {
        if let funcCall = syntax.as(FunctionCallExprSyntax.self),
            let callee = funcCall.calledExpression.as(DeclReferenceExprSyntax.self),
            callee.baseName.text == "Group",
            let trailingClosure = funcCall.trailingClosure
        {
            // Group { ... } — each statement is a separate preview
            for statement in trailingClosure.statements {
                addSingleProviderPreview(from: statement.item, node: Syntax(statement))
            }
        } else {
            addSingleProviderPreview(from: syntax, node: node)
        }
    }

    private func addSingleProviderPreview(from syntax: SyntaxProtocol, node: Syntax) {
        let closureBody = syntax.description.trimmed
        let name = extractDisplayName(from: syntax)

        let location = syntax.startLocation(
            converter: SourceLocationConverter(
                fileName: "",
                tree: syntax.root
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

    /// Check if struct has `PreviewProvider` in its inheritance clause.
    private func conformsToPreviewProvider(_ node: StructDeclSyntax) -> Bool {
        guard let inheritanceClause = node.inheritanceClause else { return false }
        return inheritanceClause.inheritedTypes.contains { inherited in
            inherited.type.description.trimmed == "PreviewProvider"
        }
    }

    /// Find `static var previews: some View { ... }` and return its code block.
    private func findPreviewsBody(in node: StructDeclSyntax) -> CodeBlockItemListSyntax? {
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                varDecl.modifiers.contains(where: { $0.name.text == "static" }),
                let binding = varDecl.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                pattern.identifier.text == "previews"
            else {
                continue
            }

            // Computed property with code block: `var previews: some View { ... }`
            if let codeBlock = binding.accessorBlock?.accessors.as(CodeBlockItemListSyntax.self) {
                return codeBlock
            }

            // Accessor block with explicit get: `var previews: some View { get { ... } }`
            if let accessorList = binding.accessorBlock?.accessors.as(AccessorDeclListSyntax.self) {
                for accessor in accessorList {
                    if accessor.accessorSpecifier.text == "get", let body = accessor.body {
                        return body.statements
                    }
                }
            }

            continue
        }
        return nil
    }

    /// Walk modifier chain to find `.previewDisplayName("...")` and extract the name.
    private func extractDisplayName(from syntax: SyntaxProtocol) -> String? {
        guard let funcCall = syntax.as(FunctionCallExprSyntax.self),
            let memberAccess = funcCall.calledExpression.as(MemberAccessExprSyntax.self),
            memberAccess.declName.baseName.text == "previewDisplayName",
            let firstArg = funcCall.arguments.first,
            let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self)
        else {
            // Check if modifier chain has .previewDisplayName deeper in the chain
            if let funcCall = syntax.as(FunctionCallExprSyntax.self),
                let memberAccess = funcCall.calledExpression.as(MemberAccessExprSyntax.self),
                let base = memberAccess.base
            {
                return extractDisplayName(from: base)
            }
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
