import ObjCLib
import SwiftLib
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            VStack {
                Text("mixed app target")
                Button("edit") {}
            }
            Text(PSGreeting.message())
            GreetingBadge()
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
