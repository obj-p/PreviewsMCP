import Testing

@testable import PreviewsCore

/// Pins the `BodyKind.rawCode` and `wireValue` numeric/string mappings.
///
/// The codes are duplicated as raw integers and string literals in two places
/// that don't link `PreviewsCore`:
/// - `Sources/PreviewsCore/PreviewBridgeSource.swift` — the `__PreviewBodyKindProbe`
///   template that gets compiled into every preview dylib.
/// - `Sources/PreviewsIOS/IOSHostAppSource.swift` — the iOS host app source template
///   that maps the dlsym'd `Int32` back to a wire string.
///
/// If anyone reorders or renumbers `BodyKind`, those untyped sites would silently
/// drift. These tests fail loudly instead — change them deliberately if you've
/// audited every duplicate.
@Suite("BodyKind code contract")
struct BodyKindCodeContractTests {
    @Test("rawCode mapping matches the probe template")
    func rawCodeMapping() {
        #expect(BodyKind.swiftUI.rawCode == 1)
        #expect(BodyKind.uiView.rawCode == 2)
        #expect(BodyKind.uiViewController.rawCode == 3)
    }

    @Test("rawCode round-trips")
    func rawCodeRoundTrip() {
        for kind in [BodyKind.swiftUI, .uiView, .uiViewController] {
            #expect(BodyKind(rawCode: kind.rawCode) == kind)
        }
    }

    @Test("rawCode init returns nil for unknown values")
    func rawCodeInvalidReturnsNil() {
        #expect(BodyKind(rawCode: 0) == nil)
        #expect(BodyKind(rawCode: 4) == nil)
        #expect(BodyKind(rawCode: -1) == nil)
        #expect(BodyKind(rawCode: Int32.max) == nil)
    }

    @Test("wireValue mapping matches the host source template")
    func wireValueMapping() {
        #expect(BodyKind.swiftUI.wireValue == "swiftUI")
        #expect(BodyKind.uiView.wireValue == "uiView")
        #expect(BodyKind.uiViewController.wireValue == "uiViewController")
    }

    @Test("wireValue round-trips")
    func wireValueRoundTrip() {
        for kind in [BodyKind.swiftUI, .uiView, .uiViewController] {
            #expect(BodyKind(wireValue: kind.wireValue) == kind)
        }
    }

    @Test("wireValue init returns nil for unknown strings")
    func wireValueInvalidReturnsNil() {
        #expect(BodyKind(wireValue: "") == nil)
        #expect(BodyKind(wireValue: "swift_ui") == nil)
        #expect(BodyKind(wireValue: "UIView") == nil)  // case-sensitive
    }
}
