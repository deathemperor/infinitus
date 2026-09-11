// Renders one phone app icon per built-in theme (#83, "Themify the app
// icons too") into ios/InfinitusMobile/Assets.xcassets/AppIcon-<id>.appiconset:
// the app icon's squircle in the theme's flash color with the theme's
// glyph over the twin-loop mark. Full-bleed 1024×1024, opaque — iOS masks
// its own corners. Run by hand after changing a theme: `swift
// make-theme-icons.swift`; the PNGs are committed. Not part of the build.
import AppKit

// id, glyph, flash color — from RowTheme's built-ins ("off" keeps the
// stock icon).
let themes: [(String, String, String)] = [
    ("rpg", "👑", "yellow"), ("movie", "🌟", "orange"), ("hades", "🌿", "red"),
    ("mgs", "🐍", "green"), ("agent", "🧠", "cyan"), ("swe", "⌨️", "blue"),
    ("scifi", "🧑\u{200D}🚀", "cyan"), ("west", "🏇", "orange"), ("cyber", "⚡", "#ff2d95"),
    ("gothic", "🕯", "purple"), ("musical", "🎷", "purple"), ("earth", "🦁", "green"),
    ("cosmo", "🪐", "indigo"), ("ocean", "⛵", "teal"),
]

func color(_ name: String) -> NSColor {
    switch name {
    case "red": return NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    case "blue": return NSColor(calibratedRed: 0.0, green: 0.48, blue: 1.0, alpha: 1)
    case "green": return NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.35, alpha: 1)
    case "yellow": return NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.0, alpha: 1)
    case "orange": return NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.0, alpha: 1)
    case "purple": return NSColor(calibratedRed: 0.69, green: 0.32, blue: 0.87, alpha: 1)
    case "indigo": return NSColor(calibratedRed: 0.35, green: 0.34, blue: 0.84, alpha: 1)
    case "cyan": return NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.98, alpha: 1)
    case "teal": return NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.98, alpha: 1)
    case "pink": return NSColor(calibratedRed: 1.0, green: 0.18, blue: 0.33, alpha: 1)
    default:
        guard name.hasPrefix("#"), name.count == 7, let v = UInt32(name.dropFirst(), radix: 16) else { return .white }
        return NSColor(calibratedRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

let px = 1024
let root = URL(fileURLWithPath: "ios/InfinitusMobile/Assets.xcassets")
for (id, glyph, flash) in themes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let tint = color(flash)
    let body = NSRect(x: 0, y: 0, width: px, height: px)
    // The stock icon's midnight ground, lit by the theme instead of cobalt.
    NSGradient(colors: [tint.blended(withFraction: 0.45, of: .black)!,
                        NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.15, alpha: 1)])!
        .draw(in: body, angle: -70)
    NSGradient(colors: [tint.withAlphaComponent(0.45), tint.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 470), radius: 0, toCenter: NSPoint(x: 512, y: 470), radius: 430, options: [])
    // The twin loop, faint, behind the glyph — still the app's mark.
    let s: CGFloat = 46
    let transform = NSAffineTransform()
    transform.translateX(by: 512 - 8.5 * s, yBy: 512 - 8.0 * s)
    transform.scale(by: s)
    NSGraphicsContext.saveGraphicsState()
    transform.concat()
    NSColor.white.withAlphaComponent(0.22).set()
    let r: CGFloat = 3.2
    for c in [NSPoint(x: 6.0, y: 8.0), NSPoint(x: 11.0, y: 8.0)] {
        let ring = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ring.lineWidth = 2.0
        ring.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    // The glyph, big and centered.
    let text = NSAttributedString(string: glyph, attributes: [.font: NSFont.systemFont(ofSize: 520)])
    let bounds = text.boundingRect(with: NSSize(width: px, height: px), options: .usesLineFragmentOrigin)
    text.draw(at: NSPoint(x: (CGFloat(px) - bounds.width) / 2, y: (CGFloat(px) - bounds.height) / 2 + 10))
    NSGraphicsContext.restoreGraphicsState()
    // Opaque RGB: an icon may not carry alpha.
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(rep.cgImage!, in: CGRect(x: 0, y: 0, width: px, height: px))
    let set = root.appendingPathComponent("AppIcon-\(id).appiconset")
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
        .write(to: set.appendingPathComponent("icon-1024.png"))
    try! """
    {
      "images" : [
        { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
    print("AppIcon-\(id)")
}
