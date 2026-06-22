import SwiftSyntax

/// Classifies a SwiftSyntax node as living in a SwiftUI- or UIKit-evaluated
/// region (#160).
///
/// The literal-only fast path mutates `DesignTimeStore.shared.values` and
/// relies on `@Observable` to drive a re-render — that's only sound for
/// SwiftUI-evaluated reads. UIKit code captures the store value once at
/// construction (`label.text = store.string("#X")`) and never observes
/// mutation, so a literal edit inside UIKit code silently no-ops on the
/// fast path. We taint such literals as `.uiKit` so `LiteralDiffer.diff`
/// can downgrade `.literalOnly` to `.structural` and force a full reload.
///
/// Lives in its own file (separate from `ThunkGenerator`/`LiteralCollector`)
/// because eligibility-checking ("should this literal be thunked at all?")
/// and region classification ("what fast-path policy applies if it is?")
/// are different concerns and were sharing a 320-line host. Public seam is
/// `classify(_:)` so future tests / callers can reach it directly.
enum LiteralRegionClassifier {

    /// Classify the syntactic region a node lives in. Walks parent nodes
    /// looking for an enclosing UIKit-typed scope: a function/var with a
    /// UIKit return type, a class extending `UIView`/`UIViewController`,
    /// a type conforming to `UIViewRepresentable`/`UIViewControllerRepresentable`,
    /// or an extension on a UIKit type. Otherwise returns `.swiftUI`.
    ///
    /// This is a syntactic heuristic. False negatives exist (e.g.
    /// `func make() -> SomeAlias` where `SomeAlias = UIView`) — they
    /// degrade to pre-#160 behavior, no worse than status quo. False
    /// positives (claiming UIKit when it's actually SwiftUI) cost only an
    /// extra reload.
    static func classify(_ node: some SyntaxProtocol) -> LiteralRegion {
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
    private static func typeNameMentionsUIKit(_ type: TypeSyntax) -> Bool {
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
        let baseName =
            bare.split(whereSeparator: { "<>?! ".contains($0) }).first.map(String.init) ?? bare
        return uikitClasses.contains(baseName)
    }

    /// Treat any inherited type that names a UIKit class or one of the SwiftUI<->UIKit
    /// representable protocols as marking the enclosing scope as UIKit-evaluated.
    private static func inheritanceMentionsUIKit(_ clause: InheritanceClauseSyntax?) -> Bool {
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
}
