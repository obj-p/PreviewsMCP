import Foundation

/// Platform-agnostic surface for a running preview session, used by MCP
/// tool handlers that need to operate on a session without branching on
/// iOS vs macOS. Backends (`MacOSPreviewHandle`, `IOSPreviewHandle`) live
/// in `PreviewsEngine` and encapsulate platform-specific work — the
/// 300ms layout-settle and `host.loadPreview` after `setTraits` on macOS,
/// the iOS host-app socket protocol on iOS — so the call site sees one
/// shape.
public protocol PreviewSessionHandle: Sendable {
    nonisolated var id: String { get }
    nonisolated var sourceFile: URL { get }
    nonisolated var platform: PreviewPlatform { get }
    var currentTraits: PreviewTraits { get async }

    /// Whether the session is still in its registry. The variants restore
    /// path uses this to skip trait restoration when a concurrent
    /// `preview_stop` has already removed the session — without the
    /// guard, the restore would surface as a spurious "failed to restore"
    /// warning when the user explicitly asked for the stop.
    var isRegistered: Bool { get async }

    /// Replace traits absolutely (no merge) and recompile. Used by
    /// `preview_variants`. macOS implementations also reload the dylib
    /// into the host window. Callers planning an immediate snapshot
    /// should call `awaitLayoutSettle()` afterward — the 300ms macOS
    /// settle is not folded into `setTraits` because the variants
    /// restore step does not snapshot and pays no settle cost.
    func setTraits(_ traits: PreviewTraits) async throws

    /// Merge traits into the current set and clear the named fields, then
    /// recompile. Used by `preview_configure`. macOS implementations also
    /// reload the dylib into the host window.
    func reconfigure(traits: PreviewTraits, clearing: Set<PreviewTraits.Field>) async throws

    /// Switch to a different `#Preview` index and recompile. Traits are
    /// preserved. macOS implementations also reload the dylib.
    func switchPreview(to index: Int) async throws

    /// Capture a screenshot. `quality >= 1.0` requests PNG output where
    /// supported; values in `[0, 1)` request JPEG at that quality.
    ///
    /// If a preceding `setTraits` / `switchPreview` / `reconfigure` call
    /// changed the rendered view, call `awaitLayoutSettle()` first. On
    /// macOS the snapshot will otherwise capture a pre-layout frame —
    /// `cacheDisplay` forces layout synchronously but does not recover
    /// from a fresh `loadPreview` swap on its own.
    func snapshot(quality: Double) async throws -> Data

    /// Wait for SwiftUI layout to settle after a fresh dylib load. macOS
    /// pauses 300ms; iOS no-ops (the host-app reload-ack already implies
    /// the new view tree is mounted). Called between `setTraits` /
    /// `switchPreview` / `reconfigure` and a subsequent `snapshot` to
    /// avoid capturing a pre-layout frame.
    func awaitLayoutSettle() async

    /// Tear down the session and unregister it from its backend's
    /// registry. After this returns, the handle should not be reused.
    func stop() async
}
