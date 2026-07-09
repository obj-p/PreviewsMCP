// Respawn-handoff spike "agent": owns a REAL native SwiftUI window at a given
// frame (Option A). Each generation is a separate process; the daemon places
// the new one at the same frame and orders it in before killing the old, so the
// preview never drops. args: label r g b x y w h
import AppKit
import SwiftUI

let a = CommandLine.arguments
let label = a[1]
let (r, g, b) = (Double(a[2])!, Double(a[3])!, Double(a[4])!)
let (x, y, w, h) = (Double(a[5])!, Double(a[6])!, Double(a[7])!, Double(a[8])!)

struct GenView: View {
    let label: String
    let color: Color
    var body: some View {
        color.overlay(
            Text(label)
                .font(.system(size: 64, weight: .bold))
                .foregroundColor(.white)
        )
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let hosting = NSHostingView(rootView: GenView(label: label, color: Color(red: r, green: g, blue: b)))
let win = NSWindow(
    contentRect: NSRect(x: x, y: y, width: w, height: h),
    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
)
win.title = "Preview"
win.isReleasedWhenClosed = false
win.contentView = hosting
win.setFrameOrigin(NSPoint(x: x, y: y))
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
FileHandle.standardError.write("agent \(label) windowNumber=\(win.windowNumber) pid=\(getpid())\n".data(using: .utf8)!)
app.run()
