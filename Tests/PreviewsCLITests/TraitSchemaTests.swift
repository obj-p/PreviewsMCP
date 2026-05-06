import MCP
import PreviewsCore
import Testing

@testable import PreviewsCLI

/// Pin the contract that `preview_start` and `preview_configure` schemas
/// derive their trait `enum` constraints from `PreviewTraits.valid*`
/// arrays — the canonical source of truth.
///
/// Catches the realistic regression: a future contributor adds a new
/// dynamic type size (or color scheme, or layout direction) to
/// `PreviewTraits` but forgets to update one of the schemas. The
/// canonical array would have N+1 entries, the schema would have N, and
/// these tests would fail with a clear "schema drifted from canonical"
/// signal.
///
/// Does not catch a contributor copy-pasting the literals inline with
/// matching values — that's a source-level concern beyond runtime tests.
/// The `ListToolsSnapshotTests` byte-snapshot will at least catch any
/// VALUE drift.
@Suite("Trait schema canonical-reference")
struct TraitSchemaTests {

    @Test("preview_start enum constraints match PreviewTraits canonical lists")
    func previewStartReferencesCanonical() {
        let props = traitProperties(in: PreviewStartHandler.schema)
        #expect(enumValues(of: props["colorScheme"]) == PreviewTraits.validColorSchemes)
        #expect(enumValues(of: props["dynamicTypeSize"]) == PreviewTraits.validDynamicTypeSizes)
        #expect(enumValues(of: props["layoutDirection"]) == PreviewTraits.validLayoutDirections)
        #expect(enumValues(of: props["legibilityWeight"]) == PreviewTraits.validLegibilityWeights)
    }

    @Test("preview_configure enum constraints match PreviewTraits canonical lists")
    func previewConfigureReferencesCanonical() {
        let props = traitProperties(in: PreviewConfigureHandler.schema)
        #expect(enumValues(of: props["colorScheme"]) == PreviewTraits.validColorSchemes)
        #expect(enumValues(of: props["dynamicTypeSize"]) == PreviewTraits.validDynamicTypeSizes)
        // Note: preview_configure doesn't enforce enums on layoutDirection
        // or legibilityWeight (it accepts empty-string-as-clear), so those
        // properties have no `enum` field. That's intentional asymmetry,
        // not drift.
    }

    @Test("both handlers agree on shared trait values")
    func handlersAgreeOnSharedValues() {
        let startProps = traitProperties(in: PreviewStartHandler.schema)
        let configureProps = traitProperties(in: PreviewConfigureHandler.schema)
        #expect(enumValues(of: startProps["colorScheme"]) == enumValues(of: configureProps["colorScheme"]))
        #expect(
            enumValues(of: startProps["dynamicTypeSize"])
                == enumValues(of: configureProps["dynamicTypeSize"])
        )
    }
}

/// Extract the `properties` object from a tool's `inputSchema`.
private func traitProperties(in tool: Tool) -> [String: Value] {
    guard case .object(let schema) = tool.inputSchema,
        case .object(let props) = schema["properties"]
    else { return [:] }
    return props
}

/// Pull the `enum` array out of a property schema as `[String]`, or `nil`
/// if the property has no `enum` constraint.
private func enumValues(of property: Value?) -> [String]? {
    guard case .object(let body) = property,
        case .array(let values) = body["enum"]
    else { return nil }
    return values.compactMap {
        if case .string(let s) = $0 { return s }
        return nil
    }
}
