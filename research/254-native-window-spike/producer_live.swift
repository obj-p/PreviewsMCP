// Live-layer spike producer: mirrors the preview AGENT exactly.
// A SwiftUI NSHostingView in an OFF-SCREEN, ordered-front borderless window
// (same as the agent's render window), whose @State changes on a timer to
// simulate input-driven updates. We vend the hosting view's REAL backing layer
// over a CAContext (ctx.layer = hosting.layer) -- NOT a raster. If the consumer
// shows the number incrementing / color flipping after binding the contextId
// once, then an off-screen agent view vends a continuously-live layer
// cross-process, which is the unknown blocking the rework.
//
// CAContext is private QuartzCore SPI, reached via the ObjC runtime (KVC).

import AppKit
import SwiftUI

struct PulseView: View {
    @State private var on = false
    @State private var count = 0
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        (on ? Color.green : Color.red)
            .overlay(
                Text("\(count)")
                    .font(.system(size: 96, weight: .bold))
                    .foregroundColor(.white)
            )
            .frame(width: 400, height: 300)
            .onReceive(timer) { _ in
                on.toggle()
                count += 1
            }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let hosting = NSHostingView(rootView: PulseView())
hosting.wantsLayer = true
hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

let win = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
    styleMask: [.borderless], backing: .buffered, defer: false
)
let onscreen = ProcessInfo.processInfo.environment["ONSCREEN"] != nil
win.setFrameOrigin(onscreen ? NSPoint(x: 60, y: 60) : NSPoint(x: -10000, y: -10000))
win.contentView = hosting
win.orderFrontRegardless()
hosting.layoutSubtreeIfNeeded()

guard let caContextClass = NSClassFromString("CAContext") as? NSObject.Type else {
    fatalError("CAContext class not found")
}
let ctx = caContextClass
    .perform(NSSelectorFromString("remoteContextWithOptions:"), with: [String: Any]())!
    .takeUnretainedValue() as! NSObject
// Retain across the run loop.
let retained = Unmanaged.passRetained(ctx)
_ = retained

guard let layer = hosting.layer else { fatalError("hosting has no layer") }
ctx.setValue(layer, forKey: "layer")
let cid = ctx.value(forKey: "contextId") as! UInt32

let path = CommandLine.arguments[1]
try? "\(cid)".write(toFile: path, atomically: true, encoding: .utf8)
FileHandle.standardError.write("producer contextId=\(cid)\n".data(using: .utf8)!)

app.run()
