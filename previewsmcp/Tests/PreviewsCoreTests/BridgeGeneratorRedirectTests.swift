import Foundation
@testable import PreviewsCore
import Testing

@Suite("BridgeGenerator resource-wrapper redirect")
struct BridgeGeneratorRedirectTests {
    private func generate(
        platform: PreviewPlatform, resourceWrapperPath: String?,
        setupModule: String? = nil, setupType: String? = nil
    ) -> String {
        BridgeGenerator.generateCombinedSource(
            originalSource: "import SwiftUI\n\n#Preview { Text(\"hi\") }",
            closureBody: "Text(\"hi\")",
            platform: platform,
            setupModule: setupModule,
            setupType: setupType,
            renderOutputPath: "/tmp/out.png",
            resourceWrapperPath: resourceWrapperPath
        ).source
    }

    @Test("a wrapper path emits the set call before the view on both platforms")
    func wrapperEmitsSetCall() {
        for platform in [PreviewPlatform.macOS, .iOS] {
            let source = generate(
                platform: platform, resourceWrapperPath: "/dd/Products/Debug/App.framework"
            )
            #expect(source.contains(#"@_silgen_name("previewsmcp_set_resource_wrapper")"#))
            let call = source.range(
                of: #"__previewsmcp_set_resource_wrapper("/dd/Products/Debug/App.framework")"#
            )
            let view = source.range(of: "let view =")
            #expect(call != nil && view != nil && call!.lowerBound < view!.lowerBound)
        }
    }

    @Test("no wrapper path emits a clearing call, not a baked path")
    func nilWrapperEmitsClearingCall() {
        for platform in [PreviewPlatform.macOS, .iOS] {
            let source = generate(platform: platform, resourceWrapperPath: nil)
            #expect(source.contains("__previewsmcp_set_resource_wrapper(nil)"))
            #expect(!source.contains(#"__previewsmcp_set_resource_wrapper(""#))
        }
    }

    @Test("a configured setup entry sets the wrapper before setUp runs")
    func setupEntryCarriesSetCall() {
        let source = generate(
            platform: .macOS, resourceWrapperPath: "/dd/App.framework",
            setupModule: "MySetup", setupType: "MySetup"
        )
        let setCall = source.range(of: #"__previewsmcp_set_resource_wrapper("/dd/App.framework")"#)
        let setUp = source.range(of: "try await MySetup.setUp()")
        #expect(setCall != nil && setUp != nil && setCall!.lowerBound < setUp!.lowerBound)
    }

    @Test("wrapper paths with quotes and backslashes are escaped into the literal")
    func wrapperPathEscaped() {
        let source = generate(
            platform: .macOS, resourceWrapperPath: #"/odd/pa"th/App.framework"#
        )
        #expect(source.contains(#"/odd/pa\"th/App.framework"#))
    }
}
