// Print "X Y W H" (top-left screen coords, points) of the first on-screen window
// whose owner executable matches arg 1. Used to derive a fixed screencapture -R
// region for the handoff spike.
import AppKit
let want = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for win in list where (win[kCGWindowOwnerName as String] as? String ?? "") == want {
    let b = win[kCGWindowBounds as String] as! [String: Any]
    print("\(Int(b["X"] as! Double)) \(Int(b["Y"] as! Double)) \(Int(b["Width"] as! Double)) \(Int(b["Height"] as! Double))")
    break
}
