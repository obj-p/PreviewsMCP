import Foundation
import MCP
@testable import PreviewsCLI
import PreviewsCore
import Testing

@Suite("Phase failure and notice carriers")
struct PhaseFailureCarrierTests {
    @Test("phaseFailureResult formats phase, message, detail, and remediation")
    func failureResultShape() {
        let result = phaseFailureResult(
            PhaseFailure(
                phase: .buildingProject, code: .incompatibleSlice,
                message: "XCFramework 'BadSlice' has no iOS simulator slice",
                detail: "available: ios-arm64",
                remediation: "Rebuild the XCFramework with a simulator slice."
            )
        )

        #expect(result.isError == true)
        guard case let .text(text) = result.content.first else {
            Issue.record("content[0] is not text")
            return
        }
        #expect(text.hasPrefix("Building the project failed: XCFramework 'BadSlice'"))
        #expect(text.contains("available: ios-arm64"))
        #expect(text.contains("Remediation: Rebuild the XCFramework"))

        guard case let .object(fields) = result.structuredContent,
              case let .object(error)? = fields["error"]
        else {
            Issue.record("structuredContent.error missing")
            return
        }
        #expect(error["phase"] == .string("buildingProject"))
        #expect(error["code"] == .string("incompatibleSlice"))
    }

    @Test("classifiedFailure derives the message from the domain error's description")
    func adapterPreservesDomainTokens() {
        let failure = classifiedFailure(
            SetupBuilderError.buildFailed(package: "BrokenPreviewSetup", stderr: "expected '}'"),
            at: .buildingProject
        )

        #expect(failure.code == .buildFailed)
        #expect(failure.message.contains("Setup package 'BrokenPreviewSetup' build failed"))
        #expect(failure.message.contains("expected '}'"))
    }

    @Test("classifiedFailure passes an existing PhaseFailure through untouched")
    func adapterPassthrough() {
        let original = PhaseFailure(
            phase: .compilingBridge, code: .unresolvedSymbols, message: "_missingSymbol"
        )
        let adapted = classifiedFailure(original, at: .buildingProject)

        #expect(adapted.phase == .compilingBridge)
        #expect(adapted.code == .unresolvedSymbols)
        #expect(adapted.message == "_missingSymbol")
    }

    @Test("appendingNotices trails content, mirrors into structuredContent, keeps content[0]")
    func noticesCarrier() {
        let base = CallTool.Result(
            content: [.text("payload")],
            structuredContent: .object(["sessionID": .string("abc")])
        )
        let notice = Notice(
            code: .agentCrashed,
            message: "The preview agent crashed and was relaunched; UI state was reset (crash #1 for this session)."
        )

        let carried = appendingNotices(base, [notice])

        guard case let .text(first) = carried.content.first else {
            Issue.record("content[0] is not text")
            return
        }
        #expect(first == "payload")
        guard case let .text(last) = carried.content.last else {
            Issue.record("trailing item is not text")
            return
        }
        #expect(last == notice.message)
        guard case let .object(fields) = carried.structuredContent else {
            Issue.record("structuredContent missing")
            return
        }
        #expect(fields["sessionID"] == .string("abc"))
        #expect(carried.noticeMessages == [notice.message])
    }

    @Test("appendingNotices creates the structured mirror when the result had none")
    func noticesMirrorCreated() {
        let carried = appendingNotices(
            CallTool.Result(content: [.text("Tap sent")]),
            [Notice(code: .ownershipLost, message: "no build system resolves the file anymore")]
        )

        #expect(carried.noticeMessages == ["no build system resolves the file anymore"])
    }

    @Test("payloadText excludes notice items so piped stdout stays clean")
    func payloadExcludesNotices() {
        let carried = appendingNotices(
            CallTool.Result(content: [.text("{\"elements\":[]}")]),
            [Notice(code: .agentCrashed, message: "crash notice")]
        )

        #expect(carried.payloadText() == "{\"elements\":[]}")
        #expect(carried.content.count == 2)
    }

    @Test("payloadText strips only the trailing notice suffix, not equal payload lines")
    func payloadKeepsEqualBodyLines() {
        let carried = appendingNotices(
            CallTool.Result(content: [.text("crash notice"), .text("payload")]),
            [Notice(code: .agentCrashed, message: "crash notice")]
        )

        #expect(carried.payloadText() == "crash notice\npayload")
    }

    @Test("detection failures classify at detectingProject, build output at buildingProject")
    func detectionVersusBuildPhase() {
        #expect(
            detectBuildContextFailure(
                BuildSystemError.buildFailed(stderr: "no such module", exitCode: 1)
            ).phase == .buildingProject
        )
        #expect(
            detectBuildContextFailure(
                BuildSystemError.ambiguousTarget(sourceFile: "A.swift", candidates: ["X", "Y"])
            ).phase == .detectingProject
        )
    }

    @Test("unresolvedSymbolsFailure parses the captured symbol list")
    func unresolvedSymbolsParsing() {
        struct JITError: LocalizedError {
            var errorDescription: String? {
                "JIT link failed: Failed to materialize symbols: { (remote.0, { _renderPreviewToFile }) }\n"
                    + "Symbols not found: [ _SCNVector3Zero, _OBJC_CLASS_$_SCNScene ]"
            }
        }

        let failure = unresolvedSymbolsFailure(from: JITError())

        #expect(failure?.phase == .rendering)
        #expect(failure?.code == .unresolvedSymbols)
        #expect(failure?.message.contains("2 symbol(s)") == true)
        #expect(failure?.message.contains("_SCNVector3Zero") == true)
        #expect(failure?.detail?.contains("_OBJC_CLASS_$_SCNScene") == true)
    }

    @Test("unresolvedSymbolsFailure ignores errors without a symbol list")
    func unresolvedSymbolsNoMatch() {
        struct Other: LocalizedError {
            var errorDescription: String? {
                "Project build failed (exit code 1)"
            }
        }

        #expect(unresolvedSymbolsFailure(from: Other()) == nil)
    }

    @Test("empty notices leave the result untouched")
    func emptyNoticesNoOp() {
        let base = CallTool.Result(content: [.text("payload")])
        let carried = appendingNotices(base, [])

        #expect(carried.content.count == 1)
        #expect(carried.structuredContent == nil)
        #expect(carried.noticeMessages.isEmpty)
        #expect(carried.payloadText() == "payload")
    }
}
