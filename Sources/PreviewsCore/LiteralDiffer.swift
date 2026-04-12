import Foundation
import SwiftParser
import SwiftSyntax

/// Result of comparing two source files for changes.
public enum ChangeKind: Sendable {
    /// Only literal values changed. Contains changed IDs and new values.
    case literalOnly(changes: [(id: String, newValue: LiteralValue)])
    /// The structure of the code changed. Requires full recompile.
    case structural
}

/// Compares old and new source to determine if only literals changed.
public enum LiteralDiffer {

    /// Compare old and new original source (before ThunkGenerator transformation).
    public static func diff(old: String, new: String) -> ChangeKind {
        let oldLiterals = collectLiterals(from: old)
        let newLiterals = collectLiterals(from: new)

        let oldSkeleton = buildSkeleton(source: old, literals: oldLiterals)
        let newSkeleton = buildSkeleton(source: new, literals: newLiterals)

        guard oldSkeleton == newSkeleton else {
            return .structural
        }

        guard oldLiterals.count == newLiterals.count else {
            return .structural
        }

        var changes: [(id: String, newValue: LiteralValue)] = []
        for (index, (oldEntry, newEntry)) in zip(oldLiterals, newLiterals).enumerated()
        where oldEntry.value != newEntry.value {
            changes.append((id: "#\(index)", newValue: newEntry.value))
        }

        return .literalOnly(changes: changes)
    }

    private static func collectLiterals(from source: String) -> [RawLiteralEntry] {
        let tree = Parser.parse(source: source)
        let collector = LiteralCollector(viewMode: .sourceAccurate)
        collector.walk(tree)
        return collector.rawEntries
    }

    private static func buildSkeleton(source: String, literals: [RawLiteralEntry]) -> String {
        var utf8 = Array(source.utf8)
        // Replace from back to front with null-byte-delimited indexed placeholders.
        // Null bytes cannot appear in valid Swift source, so these won't collide.
        for (index, entry) in literals.enumerated().reversed() {
            let placeholder = Array("\0LIT_\(index)\0".utf8)
            utf8.replaceSubrange(entry.utf8Start..<entry.utf8End, with: placeholder)
        }
        return String(decoding: utf8, as: UTF8.self)
    }
}
