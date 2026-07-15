import SwiftUI

struct NewManifestView: View {
    var body: some View {
        Text("Present in project.yml, absent from project.pbxproj")
            .padding()
    }
}

#Preview("Stale generated project") {
    NewManifestView()
}
