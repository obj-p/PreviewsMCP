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
                region: regionFor(node)
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
                    region: regionFor(node)
                ))
        } else {
            rawEntries.append(
                RawLiteralEntry(
                    value: .integer(intValue),
                    utf8Start: node.position.utf8Offset,
                    utf8End: node.endPosition.utf8Offset,
                    region: regionFor(node)
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
                    region: regionFor(node)
                ))
        } else {
            rawEntries.append(
                RawLiteralEntry(
                    value: .float(doubleValue),
                    utf8Start: node.position.utf8Offset,
                    utf8End: node.endPosition.utf8Offset,
                    region: regionFor(node)
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
                region: regionFor(node)
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

    // MARK: - Region classification (#160)
    //
    // Classifies each literal as living in either a SwiftUI- or UIKit-evaluated
    // region. The literal-only fast path mutates `DesignTimeStore.shared.values`
    // and relies on `@Observable` to drive a re-render — that's only sound for
    // SwiftUI-evaluated reads. UIKit code captures the store value once at
    // construction (`label.text = store.string("#X")`) and never observes
    // mutation, so a literal edit inside UIKit code silently no-ops on the
    // fast path. We taint such literals as `.uiKit` so `LiteralDiffer.diff`
    // can downgrade `.literalOnly` to `.structural` and force a full reload.
    //
    // This is a syntactic heuristic. False negatives exist (e.g.
    // `func make() -> SomeAlias` where `SomeAlias = UIView`), but they
    // degrade to today's behavior — no worse than status quo. False positives
    // (claiming UIKit when it's actually SwiftUI) cost only an extra reload.
    private func regionFor(_ node: some SyntaxProtocol) -> LiteralRegion {
        var current: Syntax? = Syntax(node)
        while let parent = current?.parent {
            if let funcDecl = parent.as(FunctionDeclSyntax.self) {
                if let returnClause = funcDecl.signature.returnClause,
                    typeNameMentionsUIKit(returnClause.type)
                {
                    return .uiKit
                }
            }
            if let varDecl = parent.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings {
                    if let typeAnnotation = binding.typeAnnotation,
                        typeNameMentionsUIKit(typeAnnotation.type)
                    {
                        return .uiKit
                    }
                }
            }
            if let classDecl = parent.as(ClassDeclSyntax.self),
                inheritanceMentionsUIKit(classDecl.inheritanceClause)
            {
                return .uiKit
            }
            if let structDecl = parent.as(StructDeclSyntax.self),
                inheritanceMentionsUIKit(structDecl.inheritanceClause)
            {
                return .uiKit
            }
            if let extensionDecl = parent.as(ExtensionDeclSyntax.self) {
                if typeNameMentionsUIKit(extensionDecl.extendedType)
                    || inheritanceMentionsUIKit(extensionDecl.inheritanceClause)
                {
                    return .uiKit
                }
            }
            current = parent
        }
        return .swiftUI
    }

    /// Match the type's textual representation against known UIKit class names.
    /// Catches: `UIView`, `UIViewController`, `UIKit.UIView`, common subclasses
    /// (`UILabel`, `UIButton`, `UIScrollView`, etc.), and `UIViewRepresentable.UIViewType`
    /// associated-type returns.
    ///
    /// Uses word-boundary matching so identifiers that merely *embed* `UIView`
    /// (e.g. `MyUIViewSubclass`, `UIViewable`) don't get false-positive tainted.
    /// False positives cost only an extra reload, but precision is cheap here.
    private func typeNameMentionsUIKit(_ type: TypeSyntax) -> Bool {
        let text = type.trimmedDescription
        // \bUIView(Controller)?\b matches `UIView` and `UIViewController` as whole
        // identifiers, including when wrapped (`[UIView]`, `UIView?`, `UIKit.UIView`).
        if text.range(of: #"\bUIView(Controller)?\b"#, options: .regularExpression) != nil {
            return true
        }
        // Common UIKit class names that don't fit the UIView* prefix.
        let uikitClasses: Set<String> = [
            "UILabel", "UIButton", "UIImageView", "UIScrollView", "UITableView",
            "UICollectionView", "UIStackView", "UISwitch", "UISlider", "UIStepper",
            "UISegmentedControl", "UIPageControl", "UIProgressView", "UIActivityIndicatorView",
            "UITextField", "UITextView", "UIControl", "UIWindow",
            "UINavigationController", "UITabBarController", "UISplitViewController",
            "UIPageViewController", "UIAlertController", "UISearchController",
            "UITableViewCell", "UICollectionViewCell",
        ]
        // Strip module prefix and generic args for the contains check.
        let bare = text.split(separator: ".").last.map(String.init) ?? text
        let baseName = bare.split(whereSeparator: { "<>?! ".contains($0) }).first.map(String.init) ?? bare
        return uikitClasses.contains(baseName)
    }

    /// Treat any inherited type that names a UIKit class or one of the SwiftUI<->UIKit
    /// representable protocols as marking the enclosing scope as UIKit-evaluated.
    private func inheritanceMentionsUIKit(_ clause: InheritanceClauseSyntax?) -> Bool {
        guard let clause else { return false }
        for entry in clause.inheritedTypes {
            let text = entry.type.trimmedDescription
            if text.contains("UIViewRepresentable") || text.contains("UIViewControllerRepresentable") {
                return true
            }
            if typeNameMentionsUIKit(entry.type) {
                return true
            }
        }
        return false
    }

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
