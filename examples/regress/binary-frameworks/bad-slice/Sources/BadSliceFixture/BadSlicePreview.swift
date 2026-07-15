import BadSlice
import SwiftUI

struct BadSliceView: View {
    var body: some View {
        Text(String(cString: bad_slice_message()))
            .padding()
    }
}

#Preview("Device-only XCFramework slice") {
    BadSliceView()
}
