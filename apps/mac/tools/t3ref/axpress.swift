// axpress — the harness's read-only UI driver: find and press ONE control in
// another app's accessibility tree, by label, with a frontmost/pid guard.
//
//   axpress dump  <pid>
//   axpress win   <pid>
//   axpress find  <pid> <label> [--exact] [--in x,y,w,h] [--index N]
//   axpress press <pid> <label> [--exact] [--in x,y,w,h] [--index N] [--no-front]
//
// `find` exits 0 when a pressable control matches and 4 when none does — that
// is how the capture scripts tell an OPEN right panel from a closed one
// without toggling blind. `press` performs `AXPress` on the match, and only
// after the target pid is verified frontmost: a press is the one thing here
// that changes what is on screen, and this Mac runs two debug apps plus the
// user's real reference app side by side.
//
// Pressable roles are AXButton, AXCheckBox, AXRadioButton and AXTab: the
// reference's right-panel toggle is a CHECKBOX ("Toggle right panel"), not a
// button, and its tab strip's items are buttons — matching one role only
// misses half the strip.
import AppKit
import ApplicationServices

let pressableRoles: Set<String> = [
    kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, "AXTab",
]

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &value) == .success else { return nil }
    return value
}
func str(_ e: AXUIElement, _ name: String) -> String? { attr(e, name) as? String }
func children(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func frame(_ e: AXUIElement) -> CGRect {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return .zero }
    var origin = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &origin)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: origin, size: size)
}
func labels(_ e: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute]
        .compactMap { str(e, $0) }.filter { !$0.isEmpty }
}

func walk(_ e: AXUIElement, _ path: String, _ depth: Int, _ visit: (AXUIElement, String, Int) -> Void) {
    visit(e, path, depth)
    guard depth < 40 else { return }
    for (i, c) in children(e).enumerated() { walk(c, "\(path).\(i)", depth + 1, visit) }
}

func die(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(code)
}

let args = CommandLine.arguments
guard args.count >= 3, let pid = Int32(args[2]) else {
    die("usage: axpress <dump|win|find|press> <pid> [label] [--exact] [--in x,y,w,h] [--index N]", 2)
}
guard AXIsProcessTrusted() else { die("not accessibility-trusted", 3) }
let app = AXUIElementCreateApplication(pid)
guard NSRunningApplication(processIdentifier: pid) != nil else { die("no process \(pid)", 6) }

var exact = false, index = 0, region: CGRect? = nil, requireFront = true
var i = 4
while i < args.count {
    switch args[i] {
    case "--exact": exact = true
    // Only for an app this harness owns (a fixture debug build), and only
    // when another copy of it holds the front: an AXPress is addressed at an
    // element inside THIS pid's tree, so unlike a synthesized key or click it
    // cannot land in the wrong app. The reference app is never pressed this
    // way.
    case "--no-front": requireFront = false
    case "--index":
        i += 1
        index = Int(args[i]) ?? 0
    case "--in":
        i += 1
        let n = args[i].split(separator: ",").compactMap { Double($0) }
        guard n.count == 4 else { die("--in wants x,y,w,h", 2) }
        region = CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    default: die("unknown option \(args[i])", 2)
    }
    i += 1
}

if args[1] == "win" {
    // `id w h x y` per on-screen window of THIS pid — winlist matches on the
    // app name, which cannot tell two debug Infinitus processes apart, and a
    // `--in` rect needs the window's origin, which winlist does not print.
    let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid
        && (w[kCGWindowLayer as String] as? Int ?? 0) == 0 {
        let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
        print("\(w[kCGWindowNumber as String] as? Int ?? -1) \(Int(b["Width"] ?? 0)) \(Int(b["Height"] ?? 0)) \(Int(b["X"] ?? 0)) \(Int(b["Y"] ?? 0))")
    }
    exit(0)
}
if args[1] == "dump" {
    walk(app, "0", 0) { e, path, depth in
        let role = str(e, kAXRoleAttribute) ?? "?"
        let f = frame(e)
        let geo = f.isEmpty ? "" : String(format: " @%.0f,%.0f %.0fx%.0f", f.minX, f.minY, f.width, f.height)
        let bits = labels(e).map { $0.prefix(90) }.joined(separator: " | ")
        print("\(String(repeating: " ", count: depth))\(path) \(role)\(geo) \(bits)")
    }
    exit(0)
}
guard ["find", "press"].contains(args[1]), args.count >= 4 else {
    die("usage: axpress <dump|win|find|press> <pid> [label] [--exact] [--in x,y,w,h] [--index N]", 2)
}
let needle = args[3]

var hits: [(AXUIElement, String, CGRect)] = []
walk(app, "0", 0) { e, path, _ in
    guard pressableRoles.contains(str(e, kAXRoleAttribute) ?? "") else { return }
    let texts = labels(e)
    guard texts.contains(where: { exact ? $0 == needle : $0.contains(needle) }) else { return }
    let f = frame(e)
    if let region, !region.intersects(f) { return }
    hits.append((e, "\(path) \(str(e, kAXRoleAttribute) ?? "?") \(texts.joined(separator: " | "))", f))
}
for (n, hit) in hits.enumerated() {
    print(String(format: "[%d] %@ @%.0f,%.0f %.0fx%.0f", n, hit.1, hit.2.minX, hit.2.minY, hit.2.width, hit.2.height))
}
guard index < hits.count else { die("no pressable control matching \(needle)", 4) }
if args[1] == "find" { exit(0) }

// The guard: a press changes what is on screen, so the app that gets it must
// be the one asked for. `activate` is asynchronous and two other apps here
// fight for the front, so poll.
// A command-line tool has no activation privileges of its own, so asking
// NSRunningApplication alone leaves whatever was in front there: the window
// itself is raised and made main through the target's OWN accessibility tree
// as well, which is what actually brings an Electron or AppKit app forward.
let running = NSRunningApplication(processIdentifier: pid)!
for _ in 0..<12 where requireFront {
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
    running.activate(options: [.activateAllWindows])
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window = children(app).filter({ str($0, kAXRoleAttribute) == kAXWindowRole })
        .max(by: { frame($0).width * frame($0).height < frame($1).width * frame($1).height }) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
    }
    usleep(400_000)
}
if requireFront {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
        die("frontmost is \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), not \(pid) — pressed nothing", 8)
    }
} else if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
    FileHandle.standardError.write("warning: --no-front, pressing pid \(pid) while it is not frontmost\n".data(using: .utf8)!)
}
let err = AXUIElementPerformAction(hits[index].0, kAXPressAction as CFString)
print("pressed [\(index)] \(hits[index].1) → \(err.rawValue)")
if err != .success { exit(5) }
