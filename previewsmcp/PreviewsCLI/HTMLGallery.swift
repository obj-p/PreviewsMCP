import Foundation

/// Renders a `SnapshotAllCommand.Manifest` into a self-contained static HTML
/// gallery. Images are referenced by their manifest-relative paths, so the
/// gallery is portable as long as it sits beside the `images/` directory the
/// batch wrote.
enum HTMLGallery {
    static func render(_ manifest: SnapshotAllCommand.Manifest) -> String {
        let cards = manifest.entries.map(card).joined(separator: "\n")
        let summary =
            "\(manifest.imageCount) rendered · \(manifest.skippedCount) skipped · "
                + "\(manifest.errorCount) failed · \(manifest.previewCount) previews"

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Preview Gallery</title>
        <style>
        :root { color-scheme: light dark; }
        body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem; }
        h1 { font-size: 1.25rem; }
        .summary { color: #888; margin-bottom: 1.5rem; }
        .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)); gap: 1rem; }
        .card { border: 1px solid #8883; border-radius: 8px; padding: 0.75rem; }
        .card img { width: 100%; height: auto; border-radius: 4px; background: #8881; }
        .card .name { font-weight: 600; margin-top: 0.5rem; }
        .card .meta { color: #888; font-size: 0.85rem; word-break: break-all; }
        .card.skipped, .card.error { color: #888; }
        .card .status { font-size: 0.85rem; }
        .card.error .status { color: #c0392b; }
        </style>
        </head>
        <body>
        <h1>Preview Gallery</h1>
        <div class="summary">\(escape(summary))</div>
        <div class="grid">
        \(cards)
        </div>
        </body>
        </html>
        """
    }

    private static func card(_ entry: SnapshotAllCommand.ManifestEntry) -> String {
        let title = escape(entry.name ?? "Preview [\(entry.index)]")
        let variantLabel = entry.variant.map { " · \(escape($0))" } ?? ""
        let meta = escape((entry.file as NSString).lastPathComponent) + ":\(entry.line)"

        let body: String
        switch entry.status {
        case .ok:
            let src = escape(entry.image ?? "")
            body = "<img src=\"\(src)\" alt=\"\(title)\" loading=\"lazy\">"
        case .skipped:
            body = "<div class=\"status\">skipped: \(escape(entry.error ?? ""))</div>"
        case .error:
            body = "<div class=\"status\">error: \(escape(entry.error ?? ""))</div>"
        }

        return """
        <div class="card \(entry.status.rawValue)">
        \(body)
        <div class="name">\(title)\(variantLabel)</div>
        <div class="meta">\(meta)</div>
        </div>
        """
    }

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
