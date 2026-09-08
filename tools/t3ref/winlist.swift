import CoreGraphics
import Foundation
// winlist <owner-substring> — prints "id width height" of the first normal-layer window of that app.
let want = CommandLine.arguments.dropFirst().first ?? ""
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowLayer"] as? Int) == 0 && ((w["kCGWindowOwnerName"] as? String) ?? "").contains(want) {
    let b = w["kCGWindowBounds"] as! [String: Any]
    print(w["kCGWindowNumber"] as! Int, Int(b["Width"] as! Double), Int(b["Height"] as! Double)); exit(0)
}
exit(1)
