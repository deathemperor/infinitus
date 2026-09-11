import CoreGraphics
import Foundation
// winlist <owner-substring> [title-substring|WxH] — prints "id width height" of
// that app's first matching normal-layer window.
//
// The filter picks ONE window out of an app that has several: Infinitus keeps
// the menu-bar pop-out on the same layer as the workspace, and the pop-out is
// listed first whenever it is open (#442). A `1378x823` argument matches the
// window bounds exactly — the reliable key here, since `kCGWindowName` is only
// populated for a process holding Screen Recording permission. Anything else is
// matched as a substring of the window's title.
let args = CommandLine.arguments.dropFirst()
let want = args.first ?? ""
let filter = args.dropFirst().first
let size: (Int, Int)? = filter.flatMap {
    let parts = $0.split(separator: "x")
    guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
    return (w, h)
}
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowLayer"] as? Int) == 0 && ((w["kCGWindowOwnerName"] as? String) ?? "").contains(want) {
    let b = w["kCGWindowBounds"] as! [String: Any]
    let width = Int(b["Width"] as! Double), height = Int(b["Height"] as! Double)
    if let size, (width, height) != size { continue }
    if size == nil, let filter, !((w["kCGWindowName"] as? String) ?? "").contains(filter) { continue }
    print(w["kCGWindowNumber"] as! Int, width, height); exit(0)
}
exit(1)
