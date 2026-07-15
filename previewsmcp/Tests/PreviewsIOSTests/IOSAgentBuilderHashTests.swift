import CryptoKit
import Foundation
@testable import PreviewsIOS
import Testing

/// Pin the byte-shape of the iOS agent app artifacts (source, plist,
/// icon) used by `IOSAgentBuilder.sourceHash`. The hash is the cache
/// invariant: an identical hash before and after the agent-app
/// extraction refactor (#7) proves the plugin-generated constants
/// produce a runtime String identical to the previous hand-written
/// triple-quoted blob.
///
/// The expected hash was captured from the pre-refactor codebase. If
/// it changes intentionally (someone edits the agent app or icon),
/// update the constant; the change should land in the same PR as the
/// edit so future readers can trace the value.
@Suite("IOSAgentBuilder source hash")
struct IOSAgentBuilderHashTests {
    @Test("source/plist/icon hash is stable across refactors")
    func hashIsStable() {
        var hasher = SHA256()
        hasher.update(data: Data(IOSAgentAppSource.code.utf8))
        hasher.update(data: Data(IOSAgentAppSource.infoPlist.utf8))
        hasher.update(data: IOSAppIconData.bytes)
        let digest = hasher.finalize()
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        // Pre-refactor value. If the iOS agent-app source, the Info.plist,
        // or the AppIcon.png bytes change, this value MUST be updated
        // (and the change should land in the same PR as the edit).
        // Updated 2026-05-06 for #160: AgentApp.swift gained body-kind probe
        // dlsym + reloadAck/init handshake reporting.
        // Updated 2026-06-15 for iOS JIT: AgentApp.swift gained the
        // PREVIEWSMCP_IOS_JIT --jit-port branch that starts the in-app ORC
        // executor, and the dylib-arg guard no longer fails in JIT mode.
        // Updated 2026-06-15 for iOS JIT render: JIT mode installs a placeholder
        // root view controller at launch so UIKit's end-of-launch assertion
        // doesn't abort before the first render over EPC.
        // Updated 2026-06-15 for dylib Phase B: iOS is JIT-only now, so AgentApp.swift
        // dropped all dylib loading (loadPreview/showError/applyLiterals, the
        // --dylib/--setup-dylib args, and the reload/init/literals handlers).
        // Updated 2026-06-16 for iOS JIT mandatory: the --jit-port branch and the
        // startJITExecutor/connectLoopback helpers are no longer behind #if.
        // Updated 2026-06-17 for #221 reclaim: AgentApp.swift reports resident memory
        // to the daemon once a second over the JSON channel (startMemoryReporting).
        // Updated 2026-06-20 for icon rebrand: AppIcon.png redrawn in the dark
        // Xcode color scheme (assets/icon.svg).
        // Updated 2026-06-20 for Option 2: AgentApp.swift is now a SwiftUI App
        // (WindowGroup + PreviewStore) hosted cross-process by the shell, the
        // Info.plist scene manifest uses empty UISceneConfigurations, and the
        // render installs via previewsmcp_set_preview_vc.
        // Updated 2026-06-20 for shell-owns-agent Stage 0: AgentApp.swift gained the
        // lifecycle breadcrumb (sendLifecycle + applicationDidBecomeActive/
        // applicationDidEnterBackground reporting applicationState over the channel).
        // Updated 2026-06-21 for Agent rebrand: Info.plist display name is now
        // "Agent" and AppIcon.png is the cyan-to-pink sync glyph (assets/agent-icon.svg).
        // Updated 2026-06-21 for agent->shell redirect: AgentApp.swift bounces a
        // direct foreground to the shell via the private LSApplicationWorkspace
        // (silent), gated so the hosted-launch transient .active does not bounce.
        // Updated 2026-06-21 for #217: AgentApp.swift reports an in-app JIT executor
        // failure (connect/executor) to the daemon over the JSON channel.
        // Updated 2026-06-21 for agent-icon arrows: AppIcon.png redrawn with the
        // top arrow solid pink and the bottom arrow solid cyan, dropping the
        // gradient bleed (assets/agent-icon.svg).
        // Updated 2026-06-21 for #258 host->agent rename: Info.plist bundle id is
        // now com.previewsmcp.agent (executable PreviewsMCPAgent), AgentApp.swift
        // renamed its delegate/log prefixes from PreviewHost to PreviewAgent, and
        // its memory-reporting comment dropped the stale memory-cap relaunch claim.
        // Updated 2026-07-09 for agent-icon arrowheads: AppIcon.png redrawn with
        // filled arrowheads matching assets/agent-icon.svg.
        let expected = "b0f2df2a851bf926023e1a9162406e7e176f96be01489e010f4259f5af26f3c8"
        #expect(hash == expected, "agent-app artifact hash drifted (was \(expected), now \(hash))")
    }
}
