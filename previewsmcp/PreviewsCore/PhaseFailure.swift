import Foundation

/// One error carrier for everything a phase can fail with
/// (docs/phase-error-protocol.md). Domain enums remain the internal
/// throwing vocabulary; the boundary adapter in PreviewsCLI maps them
/// into this shape, deriving `message` from their `errorDescription` so
/// pinned guard tokens survive by construction.
public struct PhaseFailure: Error, LocalizedError, Sendable {
    public let phase: BuildPhase
    public let code: FailureCode
    /// One-line classification. Stable tokens: guards pin identifiers and
    /// commands from this line, never connective prose.
    public let message: String
    /// Bounded raw evidence: the compiler stderr tail, the symbol list.
    public let detail: String?
    /// The actionable next step, when one is known.
    public let remediation: String?

    public init(
        phase: BuildPhase, code: FailureCode, message: String,
        detail: String? = nil, remediation: String? = nil
    ) {
        self.phase = phase
        self.code = code
        self.message = message
        self.detail = detail
        self.remediation = remediation
    }

    public var errorDescription: String? { message }
}

/// Only codes a designed flow actually produces; a case is added when a
/// migration reaches it, never speculatively.
public enum FailureCode: String, Sendable {
    case buildFailed
    case incompatibleSlice
    case unresolvedSymbols
    case sessionFailed
}

/// A disclosure that rides a successful response: a crash incident, a
/// setup that failed but rendered without setup, an ownership loss on a
/// live session. Appended as a trailing content item (never content[0])
/// and mirrored into `structuredContent.notices`; cleared only when a
/// response actually carried it.
public struct Notice: Sendable {
    public let code: NoticeCode
    public let message: String

    public init(code: NoticeCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum NoticeCode: String, Sendable {
    case agentCrashed
    case setupFailed
    case setupIgnored
    case ownershipLost
}
