import ObjCLib
import SwiftUI

public struct GreetingBadge: View {
    public init() {}

    public var body: some View {
        Label(PSGreeting.message(), systemImage: "tag")
            .padding(6)
            .background(.yellow, in: Capsule())
    }
}
