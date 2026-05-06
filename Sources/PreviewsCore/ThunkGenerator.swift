import Foundation
import SwiftParser
import SwiftSyntax

/// Transforms Swift source code by replacing eligible literals with `DesignTimeStore` lookups.
public enum ThunkGenerator {

    public struct Result: Sendable {
        /// The transformed source with literals replaced.
        public let source: String
        /// Literals found, in sequential order.
        public let literals: [LiteralEntry]
    }

    /// Transform source code, replacing eligible literals with DesignTimeStore calls.
    public static func transform(source: String) -> Result {
        let tree = Parser.parse(source: source)
        let collector = LiteralCollector(viewMode: .sourceAccurate)
        collector.walk(tree)

        // Build entries with sequential IDs
        var entries: [LiteralEntry] = []
        for (index, raw) in collector.rawEntries.enumerated() {
            entries.append(
                LiteralEntry(
                    id: "#\(index)",
                    value: raw.value,
                    utf8Start: raw.utf8Start,
                    utf8End: raw.utf8End,
                    region: raw.region
                ))
        }

        // Apply replacements back-to-front so offsets stay valid
        var utf8 = Array(source.utf8)
        for (index, raw) in collector.rawEntries.enumerated().reversed() {
            let id = "#\(index)"
            let replacement: String
            switch raw.value {
            case .string(let s):
                let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\t", with: "\\t")
                replacement = "DesignTimeStore.shared.string(\"\(id)\", fallback: \"\(escaped)\")"
            case .integer(let n):
                replacement = "DesignTimeStore.shared.integer(\"\(id)\", fallback: \(n))"
            case .float(let d):
                replacement = "DesignTimeStore.shared.float(\"\(id)\", fallback: \(d))"
            case .boolean(let b):
                replacement = "DesignTimeStore.shared.boolean(\"\(id)\", fallback: \(b))"
            }
            utf8.replaceSubrange(raw.utf8Start..<raw.utf8End, with: Array(replacement.utf8))
        }

        let transformedSource = String(decoding: utf8, as: UTF8.self)
        return Result(source: transformedSource, literals: entries)
    }
}

// MARK: - Internal: also used by LiteralDiffer

struct RawLiteralEntry {
    let value: LiteralValue
    let utf8Start: Int
    let utf8End: Int
    let region: LiteralRegion
}

final class LiteralCollector: SyntaxVisitor {
    var rawEntries: [RawLiteralEntry] = []

    // MARK: - String literals

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard isEligible(node) else { return .visitChildren }
        guard isSimpleString(node) else { return .visitChildren }

        let text = node.segments.compactMap { segment -> String? in
            if case .stringSegment(let s) = segment { return s.content.text }
            return nil
        }.joined()

        rawEntries.append(
            RawLiteralEntry(
                value: .string(text),
                utf8Start: node.position.utf8Offset,
                utf8End: node.endPosition.utf8Offset,
                region: LiteralRegionClassifier.classify(node)
            ))
        return .skipChildren
    }

    // MARK: - Integer literals

    override func visit(_ node: IntegerLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard isEligible(node) else { return .visitChildren }

        let text = node.literal.text.filter { $0 != "_" }
        let value: Int?
        if text.hasPrefix("0x") || text.hasPrefix("0X") {
            value = Int(text.dropFirst(2), radix: 16)
        } else if text.hasPrefix("0o") || text.hasPrefix("0O") {
            value = Int(text.dropFirst(2), radix: 8)
        } else if text.hasPrefix("0b") || text.hasPrefix("0B") {
            value = Int(text.dropFirst(2), radix: 2)
        } else {
            value = Int(text)
        }

        guard let intValue = value else { return .visitChildren }

        // Check for negation: if parent is PrefixOperatorExprSyntax with "-"
        if let prefix = node.parent?.as(PrefixOperatorExprSyntax.self),
            prefix.operator.text == "-"
        {
            rawEntries.append(
                RawLiteralEntry(
                    value: .integer(-intValue),
                    utf8Start: prefix.position.utf8Offset,
                    utf8End: prefix.endPosition.utf8Offset,
                    region: LiteralRegionClassifier.classify(node)
                ))
        } else {
            rawEntries.append(
                RawLiteralEntry(
                    value: .integer(intValue),
                    utf8Start: node.position.utf8Offset,
                    utf8End: node.endPosition.utf8Offset,
                    region: LiteralRegionClassifier.classify(node)
                ))
        }
        return .skipChildren
    }

    // MARK: - Float literals

    override func visit(_ node: FloatLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard isEligible(node) else { return .visitChildren }

        let text = node.literal.text.filter { $0 != "_" }
        guard let doubleValue = Double(text) else { return .visitChildren }

        if let prefix = node.parent?.as(PrefixOperatorExprSyntax.self),
            prefix.operator.text == "-"
        {
            rawEntries.append(
                RawLiteralEntry(
                    value: .float(-doubleValue),
                    utf8Start: prefix.position.utf8Offset,
                    utf8End: prefix.endPosition.utf8Offset,
                    region: LiteralRegionClassifier.classify(node)
                ))
        } else {
            rawEntries.append(
                RawLiteralEntry(
                    value: .float(doubleValue),
                    utf8Start: node.position.utf8Offset,
                    utf8End: node.endPosition.utf8Offset,
                    region: LiteralRegionClassifier.classify(node)
                ))
        }
        return .skipChildren
    }

    // MARK: - Boolean literals

    override func visit(_ node: BooleanLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard isEligible(node) else { return .visitChildren }

        let value = node.literal.tokenKind == .keyword(.true)
        rawEntries.append(
            RawLiteralEntry(
                value: .boolean(value),
                utf8Start: node.position.utf8Offset,
                utf8End: node.endPosition.utf8Offset,
                region: LiteralRegionClassifier.classify(node)
            ))
        return .skipChildren
    }

    // MARK: - Eligibility checks

    private func isEligible(_ node: some SyntaxProtocol) -> Bool {
        isInsideCodeBlock(node)
            && !isMacroArgument(node)
            && !isInsideImport(node)
            && !isInsideAttribute(node)
            && !isSwitchCasePattern(node)
            && !isEnumRawValue(node)
            && !isInsideIfConfig(node)
            && !isTagArgument(node)
    }

    private func isTagArgument(_ node: some SyntaxProtocol) -> Bool {
        // .tag(0) — the literal is a direct argument to a function named "tag"
        // which is an identity marker, not a design-time tweakable value
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if let call = parent.as(FunctionCallExprSyntax.self) {
                if let member = call.calledExpression.as(MemberAccessExprSyntax.self),
                    member.declName.baseName.text == "tag"
                {
                    return true
                }
                return false
            }
            if parent.is(CodeBlockSyntax.self) || parent.is(ClosureExprSyntax.self) {
                return false
            }
            current = parent
        }
        return false
    }

    private func isInsideCodeBlock(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.is(CodeBlockSyntax.self)
                || parent.is(AccessorDeclSyntax.self)
                || parent.is(AccessorBlockSyntax.self)
                || parent.is(ClosureExprSyntax.self)
            {
                return true
            }
            // Stored property initializer: PatternBindingSyntax with an initializer
            // but no accessor block. Computed properties have accessor blocks and
            // we'll hit CodeBlockSyntax/AccessorDeclSyntax before reaching here.
            if let binding = parent.as(PatternBindingSyntax.self) {
                // If this binding has an initializer and no accessors, it's a stored property
                if binding.initializer != nil && binding.accessorBlock == nil {
                    return false
                }
            }
            current = parent
        }
        return false
    }

    private func isMacroArgument(_ node: some SyntaxProtocol) -> Bool {
        // Walk up to find if we're directly in a macro's argument list
        // (not inside a trailing closure or nested function call)
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            // If we hit a closure or function call before a macro, we're not a macro argument
            if parent.is(ClosureExprSyntax.self)
                || parent.is(FunctionCallExprSyntax.self)
                || parent.is(CodeBlockSyntax.self)
            {
                return false
            }
            // If we're in a macro's labeled argument list, we ARE a macro argument
            if parent.is(MacroExpansionExprSyntax.self)
                || parent.is(MacroExpansionDeclSyntax.self)
            {
                // Only if we came through the arguments, not the trailing closure
                if current?.is(ClosureExprSyntax.self) == true {
                    return false
                }
                return true
            }
            current = parent
        }
        return false
    }

    private func isInsideImport(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.is(ImportDeclSyntax.self) { return true }
            current = parent
        }
        return false
    }

    private func isInsideAttribute(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.is(AttributeSyntax.self) { return true }
            current = parent
        }
        return false
    }

    private func isSwitchCasePattern(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.is(SwitchCaseLabelSyntax.self) { return true }
            current = parent
        }
        return false
    }

    private func isEnumRawValue(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.is(EnumCaseElementSyntax.self) { return true }
            current = parent
        }
        return false
    }

    private func isInsideIfConfig(_ node: some SyntaxProtocol) -> Bool {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if parent.is(IfConfigClauseSyntax.self),
                current?.is(ExprSyntax.self) != true
            {
                // We're in the condition, not the body
                return true
            }
            current = parent
        }
        return false
    }

    // Per-literal region classification (#160) lives in
    // `LiteralRegionClassifier.swift` — separate concern from the
    // eligibility checks above (those decide *whether* to thunk; the
    // classifier decides *what fast-path policy* applies if it is).

    private func isSimpleString(_ node: StringLiteralExprSyntax) -> Bool {
        // Reject multiline
        if node.openingQuote.tokenKind == .multilineStringQuote { return false }
        // Reject raw strings
        if node.openingPounds != nil { return false }
        // Reject interpolation
        for segment in node.segments {
            if case .expressionSegment = segment { return false }
        }
        return true
    }
}
