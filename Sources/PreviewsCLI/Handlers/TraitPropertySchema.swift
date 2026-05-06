import MCP
import PreviewsCore

/// JSON-Schema property fragment for a single trait input. Used by
/// `preview_start` and `preview_configure` to expose trait overrides
/// with a consistent shape — `type: string`, optional `enum` constraint,
/// per-handler description.
///
/// The `enum` arrays read from `PreviewTraits.valid*` so the canonical
/// list of accepted values lives in one place. Handlers spell out their
/// own descriptions (e.g., `preview_configure` adds "Pass empty string
/// to clear" hints that `preview_start` doesn't need) — only the value
/// list is shared.
func traitProperty(enumValues: [String]? = nil, description: String) -> Value {
    var members: [(String, Value)] = [("type", .string("string"))]
    if let enumValues {
        members.append(("enum", .array(enumValues.map { .string($0) })))
    }
    members.append(("description", .string(description)))
    return .object(Dictionary(uniqueKeysWithValues: members))
}
