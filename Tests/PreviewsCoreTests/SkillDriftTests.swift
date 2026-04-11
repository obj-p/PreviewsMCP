import Foundation
import Testing

/// Static eval: parse `docs/skills/previewsmcp.md` and assert every tool and trait
/// preset it mentions exists in the live source. Catches mechanical drift
/// (renames, removals, additions) in CI without running the MCP server.
///
/// This is a text-level eval — it reads source files as strings rather than
/// importing PreviewsCLI, so it works as a plain PreviewsCoreTests test with no
/// extra build dependencies.
@Suite("SkillDrift")
struct SkillDriftTests {

    // MARK: - Package layout

    /// Walk up from this test file to the package root (contains Package.swift).
    private static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("Package.swift").path)
            {
                return url
            }
        }
        fatalError("could not locate package root from \(#filePath)")
    }()

    private static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: packageRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - Sources of truth

    /// Tool names declared in `private enum ToolName: String { ... }` in MCPServer.swift.
    private static func registeredToolNames() throws -> Set<String> {
        let source = try read("Sources/PreviewsCLI/MCPServer.swift")
        guard let header = source.range(of: "enum ToolName: String {") else {
            Issue.record("could not find ToolName enum in MCPServer.swift")
            return []
        }
        let tail = source[header.upperBound...]
        guard let closing = tail.range(of: "}") else { return [] }
        let body = tail[..<closing.lowerBound]

        var names = Set<String>()
        for line in body.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("case "),
                let eq = trimmed.range(of: "= \"")
            else { continue }
            let afterOpen = trimmed[eq.upperBound...]
            guard let closeQuote = afterOpen.firstIndex(of: "\"") else { continue }
            names.insert(String(afterOpen[..<closeQuote]))
        }
        return names
    }

    /// Valid trait preset names: `validColorSchemes ∪ validDynamicTypeSizes` from PreviewTraits.swift.
    private static func validPresets() throws -> Set<String> {
        let source = try read("Sources/PreviewsCore/PreviewTraits.swift")
        return try extractQuotedElements(
            ofSetLiteral: "validColorSchemes", in: source)
            .union(
                extractQuotedElements(ofSetLiteral: "validDynamicTypeSizes", in: source))
    }

    /// Parse `<name>: Set<String> = [ "a", "b", ... ]` and return the quoted elements.
    private static func extractQuotedElements(
        ofSetLiteral name: String, in source: String
    ) throws -> Set<String> {
        guard let anchor = source.range(of: "\(name): Set<String> = [") else {
            Issue.record("could not find set literal `\(name)`")
            return []
        }
        let afterOpen = source[anchor.upperBound...]
        guard let closeBracket = afterOpen.firstIndex(of: "]") else { return [] }
        let body = afterOpen[..<closeBracket]

        var values = Set<String>()
        var cursor = body.startIndex
        while let openQuote = body[cursor...].firstIndex(of: "\"") {
            let afterOpenQuote = body.index(after: openQuote)
            guard let closeQuote = body[afterOpenQuote...].firstIndex(of: "\"") else { break }
            values.insert(String(body[afterOpenQuote..<closeQuote]))
            cursor = body.index(after: closeQuote)
        }
        return values
    }

    // MARK: - Skill parsing

    private static func skillContents() throws -> String {
        try read("docs/skills/previewsmcp.md")
    }

    /// Read the single comma-separated line immediately following `<!-- eval:<name> -->`.
    private static func evalBlock(_ name: String, in skill: String) -> Set<String> {
        let marker = "<!-- eval:\(name) -->"
        guard let range = skill.range(of: marker) else { return [] }
        let after = skill[range.upperBound...]
        for line in after.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            return Set(
                trimmed.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
        }
        return []
    }

    /// Scrape every `preview_*` or `simulator_*` identifier from the skill prose.
    /// Catches drift where the skill references a nonexistent tool in text even if
    /// the eval:tools block is correct.
    private static func toolMentionsInProse(_ skill: String) -> Set<String> {
        let pattern = #"(?:preview|simulator)_[a-z_]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(skill.startIndex..., in: skill)
        var mentions = Set<String>()
        regex.enumerateMatches(in: skill, range: range) { match, _, _ in
            if let m = match, let r = Range(m.range, in: skill) {
                mentions.insert(String(skill[r]))
            }
        }
        return mentions
    }

    // MARK: - Tests

    @Test("eval:tools block matches the live MCP tool registry")
    func toolsBlockMatchesRegistry() throws {
        let registered = try Self.registeredToolNames()
        let advertised = Self.evalBlock("tools", in: try Self.skillContents())

        #expect(!registered.isEmpty, "failed to extract tool names from MCPServer.swift")
        #expect(!advertised.isEmpty, "skill has no <!-- eval:tools --> block")

        let missingFromSkill = registered.subtracting(advertised)
        let extraInSkill = advertised.subtracting(registered)
        #expect(
            missingFromSkill.isEmpty,
            "tools exist in code but are not listed in the skill: \(missingFromSkill.sorted())")
        #expect(
            extraInSkill.isEmpty,
            "skill lists tools that do not exist in code: \(extraInSkill.sorted())")
    }

    @Test("eval:presets block matches PreviewTraits valid sets")
    func presetsBlockMatchesValidTraits() throws {
        let valid = try Self.validPresets()
        let advertised = Self.evalBlock("presets", in: try Self.skillContents())

        #expect(!valid.isEmpty, "failed to extract trait presets from PreviewTraits.swift")
        #expect(!advertised.isEmpty, "skill has no <!-- eval:presets --> block")

        let missingFromSkill = valid.subtracting(advertised)
        let extraInSkill = advertised.subtracting(valid)
        #expect(
            missingFromSkill.isEmpty,
            "presets exist in code but are not listed in the skill: \(missingFromSkill.sorted())")
        #expect(
            extraInSkill.isEmpty,
            "skill lists presets that do not exist in code: \(extraInSkill.sorted())")
    }

    @Test("every preview_/simulator_ identifier in skill prose exists in the registry")
    func proseToolMentionsExistInRegistry() throws {
        let registered = try Self.registeredToolNames()
        let mentioned = Self.toolMentionsInProse(try Self.skillContents())
        let unknown = mentioned.subtracting(registered)
        #expect(
            unknown.isEmpty,
            "skill prose references tools that do not exist: \(unknown.sorted())")
    }
}
