import Foundation
import PreviewsCore

/// Wire-format DTOs for the daemon's `structuredContent` payloads.
///
/// Each MCP tool handler that returns non-trivial data populates a
/// `CallTool.Result.structuredContent` field using one of these types.
/// The CLI decodes the same types back into Swift structs, so the regex-
/// parsing of human-readable prose that the CLI used to do is retired
/// in favour of a typed contract.
///
/// Human-readable `.text(...)` content blocks are kept in parallel on
/// every response so MCP clients that don't consume `structuredContent`
/// continue to work.
///
/// Types stay separate from the domain types they mirror (e.g.
/// `PreviewInfoDTO` vs `PreviewsCore.PreviewInfo`) on purpose — the
/// wire contract is allowed to drift from the in-memory representation
/// (for example, `active: Bool` is wire-only).
enum DaemonProtocol {

    // MARK: - Shared DTOs

    struct PreviewInfoDTO: Codable, Sendable, Equatable {
        let index: Int
        let name: String?
        let line: Int
        let snippet: String
        let active: Bool
    }

    /// Mirror of `PreviewsCore.PreviewTraits`. All-optional strings so
    /// the JSON object omits unset fields.
    struct TraitsDTO: Codable, Sendable, Equatable {
        let colorScheme: String?
        let dynamicTypeSize: String?
        let locale: String?
        let layoutDirection: String?
        let legibilityWeight: String?

        init(from traits: PreviewTraits) {
            self.colorScheme = traits.colorScheme
            self.dynamicTypeSize = traits.dynamicTypeSize
            self.locale = traits.locale
            self.layoutDirection = traits.layoutDirection
            self.legibilityWeight = traits.legibilityWeight
        }

        /// Returns nil when no trait fields are set, so the enclosing
        /// DTO can omit the traits field entirely via Codable's
        /// `encodeIfPresent`.
        static func orNil(_ traits: PreviewTraits) -> TraitsDTO? {
            traits.isEmpty ? nil : TraitsDTO(from: traits)
        }
    }

    // MARK: - Per-tool result payloads

    struct PreviewStartResult: Codable, Sendable, Equatable {
        let sessionID: String
        let platform: String  // "macos" | "ios"
        let sourceFilePath: String
        let deviceUDID: String?
        let pid: Int?
        let traits: TraitsDTO?
        let previews: [PreviewInfoDTO]
        let activeIndex: Int
        let setupWarning: String?
    }

    struct VariantOutcomeDTO: Codable, Sendable, Equatable {
        /// "ok" on success, "error" on failure.
        let status: String
        let index: Int
        let label: String
        /// Set on success. Points into the sibling
        /// `CallTool.Result.content` array at the `.image(...)` block
        /// holding this variant's bytes.
        let imageIndex: Int?
        /// Set on failure.
        let error: String?
    }

    struct VariantsResult: Codable, Sendable, Equatable {
        let variants: [VariantOutcomeDTO]
        let successCount: Int
        let failCount: Int
    }

    struct SwitchResult: Codable, Sendable, Equatable {
        let sessionID: String
        let activeIndex: Int
        let traits: TraitsDTO?
        let previews: [PreviewInfoDTO]
    }

    struct PreviewListResult: Codable, Sendable, Equatable {
        let file: String
        let previews: [PreviewInfoDTO]
    }

    struct SimulatorDTO: Codable, Sendable, Equatable {
        let udid: String
        let name: String
        let runtime: String?
        let state: String  // "Booted" / "Shutdown" / ...
        let isAvailable: Bool
    }

    struct SimulatorListResult: Codable, Sendable, Equatable {
        let simulators: [SimulatorDTO]
    }

    struct SessionDTO: Codable, Sendable, Equatable {
        let sessionID: String
        let platform: String  // "macos" | "ios"
        let sourceFilePath: String
    }

    struct SessionListResult: Codable, Sendable, Equatable {
        let sessions: [SessionDTO]
    }

    // Elements doesn't get a Codable DTO — the accessibility tree is
    // arbitrary nested JSON from WDA. The daemon encodes it directly
    // into a `Value.object(["sessionID": ..., "elements": <tree>])`
    // and the CLI's `--json` passthrough serializes it back verbatim.
}

// MARK: - Helpers

extension DaemonProtocol.PreviewInfoDTO {
    /// Build the wire type from a `PreviewsCore.PreviewInfo` plus the
    /// active index of the containing session.
    init(from previewInfo: PreviewInfo, activeIndex: Int) {
        self.index = previewInfo.index
        self.name = previewInfo.name
        self.line = previewInfo.line
        self.snippet = previewInfo.snippet
        self.active = previewInfo.index == activeIndex
    }
}
