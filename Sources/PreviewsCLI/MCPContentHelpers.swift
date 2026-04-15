import MCP

extension Array where Element == Tool.Content {
    /// Concatenate all text items in a tool result's content with newlines,
    /// skipping image and other non-text items. Convenient for CLI commands
    /// that want to display the daemon's human-readable response.
    func joinedText() -> String {
        compactMap { item in
            if case .text(let t) = item { return t }
            return nil
        }.joined(separator: "\n")
    }
}
