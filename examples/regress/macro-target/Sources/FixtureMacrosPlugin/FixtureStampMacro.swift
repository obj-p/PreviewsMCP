import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

public struct FixtureStampMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        "\"custom macro expansion active\""
    }
}

@main
struct FixtureMacrosPluginMain: CompilerPlugin {
    let providingMacros: [Macro.Type] = [FixtureStampMacro.self]
}
