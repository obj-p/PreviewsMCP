import PreviewsCore

/// Human-readable one-line summary of active traits.
public func traitsSummary(_ traits: PreviewTraits) -> String {
    var parts: [String] = []
    if let cs = traits.colorScheme { parts.append("colorScheme=\(cs)") }
    if let dts = traits.dynamicTypeSize { parts.append("dynamicTypeSize=\(dts)") }
    if let loc = traits.locale { parts.append("locale=\(loc)") }
    if let ld = traits.layoutDirection { parts.append("layoutDirection=\(ld)") }
    if let lw = traits.legibilityWeight { parts.append("legibilityWeight=\(lw)") }
    return parts.joined(separator: ", ")
}

/// Formatted preview list with `<- active` marker on the active index.
public func formatPreviewList(previews: [PreviewInfo], activeIndex: Int) -> String {
    var lines: [String] = ["Available previews:"]
    for preview in previews {
        let name = preview.name ?? "Preview"
        let marker = preview.index == activeIndex ? " <- active" : ""
        lines.append("  [\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)\(marker)")
    }
    return lines.joined(separator: "\n")
}
