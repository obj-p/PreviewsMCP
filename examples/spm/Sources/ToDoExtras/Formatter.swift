import Foundation

/// A small helper living in a sibling target. The fact that `ToDo` imports this
/// module exercises SPMBuildSystem's dependency linking — without the `-L <binPath>`
/// flag, compiling any file that `import`s `ToDoExtras` will fail at link time.
public enum ProgressFormatter {
    public static func summary(completed: Int, total: Int) -> String {
        guard total > 0 else { return "No items" }
        let percent = Int(Double(completed) / Double(total) * 100)
        return "\(completed)/\(total) (\(percent)%)"
    }
}

/// Package-scoped helper exercised from `ToDo`. `package` access requires the
/// consumer to be compiled with the same `-package-name` as this module —
/// without that flag on the dylib recompile, the preview build fails with
/// "cannot find 'PackageScopedLabel' in scope".
package enum PackageScopedLabel {
    package static func remaining(_ count: Int) -> String {
        count == 1 ? "1 item remaining" : "\(count) items remaining"
    }
}
