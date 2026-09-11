// Renders the Infinitus app icon — the twin loop (same ring geometry as
// MenuBarGlyph, the identity's source of truth) with the swap arrow
// breaking the right ring, over a midnight→cobalt squircle with an
// ion-cyan center glow — to the PNG path given as argv[1], at exactly
// 1024×1024 pixels. Run by make-icon.sh; not part of the SwiftPM build.
import AppKit

let out = CommandLine.arguments[1]
let px = 1024
// "ios": full-bleed square — iOS masks its own corners, so the squircle
// fills the canvas (a transparent-cornered icon shows black corners).
let fullBleed = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "ios"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Apple's icon grid: content inset ~10% per side, continuous-corner feel.
let inset: CGFloat = fullBleed ? 0 : 100
let body = NSRect(x: inset, y: inset,
                  width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
let squircle = NSBezierPath(roundedRect: body, xRadius: fullBleed ? 0 : 185,
                            yRadius: fullBleed ? 0 : 185)
NSGradient(colors: [
    NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.85, alpha: 1),  // cobalt
    NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.15, alpha: 1),  // midnight
])!.draw(in: squircle, angle: -70)

// Ion-cyan glow behind the mark so it reads as luminous, not printed.
squircle.addClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.50, green: 0.91, blue: 1.0, alpha: 0.42),
    NSColor(calibratedRed: 0.50, green: 0.91, blue: 1.0, alpha: 0.0),
])!.draw(
    fromCenter: NSPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), radius: 0,
    toCenter: NSPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), radius: 400,
    options: []
)

// The twin loop, verbatim from MenuBarGlyph's 17×16 design space,
// scaled up and centered (design-box center (8.5, 8) → canvas center).
let s: CGFloat = fullBleed ? 46 : 40
let transform = NSAffineTransform()
transform.translateX(by: 512 - 8.5 * s, yBy: 512 - 8.0 * s)
transform.scale(by: s)
transform.concat()

let r: CGFloat = 3.2
let left = NSPoint(x: 6.0, y: 8.0)
let right = NSPoint(x: 11.0, y: 8.0)

NSColor.white.set()
let stroke = NSBezierPath()
stroke.lineWidth = 2.0
stroke.lineCapStyle = .round
stroke.appendOval(in: NSRect(x: left.x - r, y: left.y - r, width: r * 2, height: r * 2))
stroke.stroke()
// The right ring is broken between 10° and 70°; the swap arrow rides
// the break, pointing clockwise — the rotation the app exists for.
// (Its own path: appendArc would otherwise join from the oval's end.)
let arc = NSBezierPath()
arc.lineWidth = 2.0
arc.lineCapStyle = .round
arc.appendArc(withCenter: right, radius: r, startAngle: 70, endAngle: 10, clockwise: false)
arc.stroke()

let a = 70.0 * CGFloat.pi / 180
let tip0 = NSPoint(x: right.x + r * cos(a), y: right.y + r * sin(a))
let t = NSPoint(x: sin(a), y: -cos(a))        // clockwise tangent
let n = NSPoint(x: cos(a), y: sin(a))         // outward normal
let head = NSBezierPath()
head.move(to: NSPoint(x: tip0.x + 2.4 * t.x, y: tip0.y + 2.4 * t.y))
head.line(to: NSPoint(x: tip0.x + 1.9 * n.x, y: tip0.y + 1.9 * n.y))
head.line(to: NSPoint(x: tip0.x - 1.9 * n.x, y: tip0.y - 1.9 * n.y))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()
if fullBleed {
    // Flatten to opaque RGB: App Store icons may not carry alpha.
    let cg = rep.cgImage!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
    let flat = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! flat.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out))
} else {
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: out))
}
