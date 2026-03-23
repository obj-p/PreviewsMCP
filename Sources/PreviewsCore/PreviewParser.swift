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
    /// 0-based index among all previews (`#Preview` blocks and `PreviewProvider` entries) in the file.
    public let index: Int
    /// Device name from `.previewDevice(PreviewDevice(rawValue: "..."))`, if present.
    public let device: String?
    /// Layout from `.previewLayout(...)`, if present. One of "sizeThatFits", "device", or "fixed(width:height:)".
    public let layout: String?

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
    /// Static computed properties from the current PreviewProvider struct, for cross-property resolution.
    var currentStaticProperties: [String: String] = [:]

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
            index: previews.count,
            device: nil,
            layout: nil
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

        // Collect static computed properties for cross-property reference resolution
        currentStaticProperties = collectStaticProperties(in: node)
        defer { currentStaticProperties = [:] }

        let items = Array(body)

        // Unwrap single `return` statement
        if items.count == 1, let returnStmt = items[0].item.as(ReturnStmtSyntax.self),
            let expr = returnStmt.expression
        {
            addPreviewProviderItems(from: expr)
        } else if items.count == 1 {
            // Single expression — check for Group or treat as one preview
            addPreviewProviderItems(from: items[0].item)
        } else {
            // Multiple statements (@ViewBuilder) — each is a separate preview
            for item in items {
                addSingleProviderPreview(from: item.item)
            }
        }

        return .skipChildren
    }

    /// Check if the expression is a `Group { ... }` or `ForEach(...)` call, and split children.
    /// Otherwise treat it as a single preview.
    private func addPreviewProviderItems(from syntax: SyntaxProtocol) {
        guard let funcCall = syntax.as(FunctionCallExprSyntax.self) else {
            addSingleProviderPreview(from: syntax)
            return
        }

        if let callee = funcCall.calledExpression.as(DeclReferenceExprSyntax.self) {
            if callee.baseName.text == "Group", let trailingClosure = funcCall.trailingClosure {
                // Group { ... } — each statement is a separate preview
                for statement in trailingClosure.statements {
                    addSingleProviderPreview(from: statement.item)
                }
                return
            }

            if callee.baseName.text == "ForEach",
                let expanded = expandForEach(funcCall)
            {
                for preview in expanded {
                    addSingleProviderPreview(from: preview)
                }
                return
            }
        }

        addSingleProviderPreview(from: syntax)
    }

    /// Try to expand `ForEach([...], id: \.self) { param in ... }` into individual preview expressions.
    /// Returns nil if the ForEach can't be statically expanded (non-literal array, etc.).
    private func expandForEach(_ funcCall: FunctionCallExprSyntax) -> [SyntaxProtocol]? {
        // Need a trailing closure with a parameter
        guard let trailingClosure = funcCall.trailingClosure,
            let signature = trailingClosure.signature,
            let paramClause = signature.parameterClause
        else {
            return nil
        }

        // Extract the closure parameter name
        let paramName: String
        if let simpleParam = paramClause.as(ClosureShorthandParameterListSyntax.self),
            let first = simpleParam.first
        {
            paramName = first.name.text
        } else if let paramList = paramClause.as(ClosureParameterClauseSyntax.self),
            let first = paramList.parameters.first
        {
            paramName = first.firstName.text
        } else {
            return nil
        }

        // Find the first argument — must be an inline array literal
        guard let firstArg = funcCall.arguments.first,
            let arrayExpr = firstArg.expression.as(ArrayExprSyntax.self)
        else {
            return nil
        }

        // Extract string literal elements from the array
        let elements: [String] = arrayExpr.elements.compactMap { element in
            if let stringLiteral = element.expression.as(StringLiteralExprSyntax.self) {
                return stringLiteral.segments.description
            }
            return nil
        }

        // All elements must be string literals for static expansion
        guard elements.count == arrayExpr.elements.count, !elements.isEmpty else {
            return nil
        }

        // Get the closure body template
        let bodyTemplate = trailingClosure.statements.description.trimmed

        // Expand: substitute each element value for the parameter name
        var results: [SyntaxProtocol] = []
        for element in elements {
            let expanded = substituteParameter(
                in: bodyTemplate, paramName: paramName, value: "\"\(element)\""
            )
            let parsed = Parser.parse(source: expanded)
            // Use the first statement from the parsed result
            if let firstStmt = parsed.statements.first {
                results.append(firstStmt.item)
            }
        }

        return results.isEmpty ? nil : results
    }

    /// Replace occurrences of `paramName` with `value` in source text,
    /// being careful to only replace whole-word matches.
    private func substituteParameter(in template: String, paramName: String, value: String) -> String {
        // Use word boundary matching to avoid replacing substrings
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: paramName))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return template
        }
        return regex.stringByReplacingMatches(
            in: template,
            range: NSRange(template.startIndex..., in: template),
            withTemplate: NSRegularExpression.escapedTemplate(for: value)
        )
    }

    private func addSingleProviderPreview(from syntax: SyntaxProtocol) {
        var resolvedSyntax: SyntaxProtocol = syntax

        // Resolve cross-property references: if the expression is a bare identifier
        // matching a static computed property, inline that property's body.
        if let declRef = syntax.as(DeclReferenceExprSyntax.self),
            let inlinedBody = currentStaticProperties[declRef.baseName.text]
        {
            let parsed = Parser.parse(source: inlinedBody)
            if let firstStmt = parsed.statements.first {
                resolvedSyntax = firstStmt.item
            }
        }

        let closureBody = resolvedSyntax.description.trimmed
        let modifiers = extractPreviewModifiers(from: resolvedSyntax)

        let location = syntax.startLocation(
            converter: SourceLocationConverter(
                fileName: "",
                tree: syntax.root
            ))

        let info = PreviewInfo(
            name: modifiers.displayName,
            closureBody: closureBody,
            line: location.line,
            column: location.column,
            index: previews.count,
            device: modifiers.device,
            layout: modifiers.layout
        )
        previews.append(info)
    }

    /// Collect all static computed properties (other than `previews`) from the struct.
    /// Returns a dictionary of property name → body source text.
    private func collectStaticProperties(in node: StructDeclSyntax) -> [String: String] {
        var props: [String: String] = [:]
        for member in node.memberBlock.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self),
                varDecl.modifiers.contains(where: { $0.name.text == "static" }),
                let binding = varDecl.bindings.first,
                let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                pattern.identifier.text != "previews"
            else {
                continue
            }
            // Computed property body
            if let codeBlock = binding.accessorBlock?.accessors.as(CodeBlockItemListSyntax.self) {
                let body = codeBlock.description.trimmed
                // Handle single-statement bodies that might have `return`
                let items = Array(codeBlock)
                if items.count == 1,
                    let returnStmt = items[0].item.as(ReturnStmtSyntax.self),
                    let expr = returnStmt.expression
                {
                    props[pattern.identifier.text] = expr.description.trimmed
                } else {
                    props[pattern.identifier.text] = body
                }
            }
        }
        return props
    }

    /// Check if struct has `PreviewProvider` in its inheritance clause.
    private func conformsToPreviewProvider(_ node: StructDeclSyntax) -> Bool {
        guard let inheritanceClause = node.inheritanceClause else { return false }
        return inheritanceClause.inheritedTypes.contains { inherited in
            let name = inherited.type.description.trimmed
            return name == "PreviewProvider" || name == "SwiftUI.PreviewProvider"
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

    /// Extracted preview modifier metadata from a PreviewProvider expression.
    private struct PreviewModifiers {
        var displayName: String?
        var device: String?
        var layout: String?
    }

    /// Walk the modifier chain to extract `.previewDisplayName`, `.previewDevice`, and `.previewLayout`.
    private func extractPreviewModifiers(from syntax: SyntaxProtocol) -> PreviewModifiers {
        var result = PreviewModifiers()
        collectPreviewModifiers(from: syntax, into: &result)
        return result
    }

    private func collectPreviewModifiers(from syntax: SyntaxProtocol, into result: inout PreviewModifiers) {
        guard let funcCall = syntax.as(FunctionCallExprSyntax.self),
            let memberAccess = funcCall.calledExpression.as(MemberAccessExprSyntax.self)
        else {
            return
        }

        let methodName = memberAccess.declName.baseName.text

        switch methodName {
        case "previewDisplayName":
            if let firstArg = funcCall.arguments.first,
                let stringLiteral = firstArg.expression.as(StringLiteralExprSyntax.self)
            {
                result.displayName = stringLiteral.segments.description
            }
        case "previewDevice":
            // .previewDevice(PreviewDevice(rawValue: "iPhone 14"))
            if let firstArg = funcCall.arguments.first,
                let deviceCall = firstArg.expression.as(FunctionCallExprSyntax.self),
                let rawValueArg = deviceCall.arguments.first(where: {
                    $0.label?.text == "rawValue"
                }),
                let stringLiteral = rawValueArg.expression.as(StringLiteralExprSyntax.self)
            {
                result.device = stringLiteral.segments.description
            }
        case "previewLayout":
            // .previewLayout(.sizeThatFits) or .previewLayout(.fixed(width: 300, height: 500))
            if let firstArg = funcCall.arguments.first {
                if let memberAccess = firstArg.expression.as(MemberAccessExprSyntax.self) {
                    result.layout = memberAccess.declName.baseName.text
                } else if let funcCallArg = firstArg.expression.as(FunctionCallExprSyntax.self),
                    let member = funcCallArg.calledExpression.as(MemberAccessExprSyntax.self)
                {
                    // .fixed(width: 300, height: 500)
                    result.layout = funcCallArg.description.trimmed
                    _ = member  // silence unused warning
                }
            }
        default:
            break
        }

        // Continue walking the chain to find more modifiers
        if let base = memberAccess.base {
            collectPreviewModifiers(from: base, into: &result)
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
