// winmove <window-id> <x> <y> [w h] — move that window's top-left corner to
// global point (x, y) in CG coordinates, and size it to w×h points when given (origin at the main display's top-left, y
// down; a display below the main one has y > its height). Goes through the
// Accessibility API of the window's own process — never System Events, which
// resolves `process whose unix id is N` by NAME and, with two processes both
// called Infinitus, moves the other one's window (2026-09-09: the user's
// pinned pop-out ended up on the laptop panel). Needs Accessibility
// permission for the calling terminal. Exit 1 when no window matches.
import AppKit
import ApplicationServices

let args = CommandLine.arguments
guard args.count == 4 || args.count == 6, let id = UInt32(args[1]), let x = Double(args[2]), let y = Double(args[3]) else {
    FileHandle.standardError.write("usage: winmove <window-id> <x> <y> [w h]\n".data(using: .utf8)!)
    exit(2)
}
let wantSize: CGSize? = args.count == 6 ? CGSize(width: Double(args[4]) ?? 0, height: Double(args[5]) ?? 0) : nil
let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]] ?? []
guard let info = list.first, let pid = info["kCGWindowOwnerPID"] as? pid_t,
      let b = info["kCGWindowBounds"] as? [String: Double],
      let w = b["Width"], let h = b["Height"], let bx = b["X"], let by = b["Y"] else {
    FileHandle.standardError.write("no window \(id)\n".data(using: .utf8)!); exit(1)
}
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString, &windows)
for win in (windows as? [AXUIElement]) ?? [] {
    var sizeRef: CFTypeRef?, posRef: CFTypeRef?
    AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef)
    AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef)
    var size = CGSize.zero, pos = CGPoint.zero
    guard let s = sizeRef, let p = posRef else { continue }
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    // AX reports the same frame CG does; match on it to pick this window
    // out of the process's others.
    guard abs(size.width - w) < 2, abs(size.height - h) < 2, abs(pos.x - bx) < 2, abs(pos.y - by) < 2 else { continue }
    var target = CGPoint(x: x, y: y)
    let err = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &target)!)
    guard err == .success else {
        FileHandle.standardError.write("move refused: AXError \(err.rawValue)\n".data(using: .utf8)!); exit(1)
    }
    if var want = wantSize {
        // After the move: a window that crossed onto another display may have
        // been re-clamped there, and the autosaved frame is only honoured when
        // its screen rect names a screen that exists — so the size is set last.
        let serr = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &want)!)
        guard serr == .success else {
            FileHandle.standardError.write("resize refused: AXError \(serr.rawValue)\n".data(using: .utf8)!); exit(1)
        }
    }
    exit(0)
}
FileHandle.standardError.write("window \(id) has no accessibility element in pid \(pid)\n".data(using: .utf8)!)
exit(1)
