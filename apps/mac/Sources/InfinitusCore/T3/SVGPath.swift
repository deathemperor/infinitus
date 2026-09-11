/// The subset of SVG path syntax lucide emits (M L H V C S Q T A Z, absolute
/// and relative), expanded to absolute commands SwiftUI's `Path` can draw.
public enum SVGPath {
    public enum Command: Equatable, Sendable {
        case move(Double, Double), line(Double, Double)
        case cubic(Double, Double, Double, Double, Double, Double)
        case quad(Double, Double, Double, Double)
        case arc(rx: Double, ry: Double, rotation: Double, large: Bool, sweep: Bool, x: Double, y: Double)
        case close
    }

    public static func parse(_ d: String) -> [Command] {
        var out: [Command] = []
        var tokens = tokenize(d)[...]
        var cx = 0.0, cy = 0.0, sx = 0.0, sy = 0.0
        var lastC: (Double, Double)? = nil, lastQ: (Double, Double)? = nil
        var cmd: Character = "M"
        func num() -> Double { let t = tokens.removeFirst(); return Double(t)! }
        while !tokens.isEmpty {
            let t = tokens.first!
            if t.count == 1, let c = t.first, c.isLetter { cmd = c; tokens.removeFirst() }
            let rel = cmd.isLowercase
            switch cmd.uppercased() {
            case "M":
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.move(x, y)); cx = x; cy = y; sx = x; sy = y; cmd = rel ? "l" : "L"; lastC = nil; lastQ = nil
            case "L":
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.line(x, y)); cx = x; cy = y; lastC = nil; lastQ = nil
            case "H": let x = num() + (rel ? cx : 0); out.append(.line(x, cy)); cx = x; lastC = nil; lastQ = nil
            case "V": let y = num() + (rel ? cy : 0); out.append(.line(cx, y)); cy = y; lastC = nil; lastQ = nil
            case "C":
                let x1 = num() + (rel ? cx : 0), y1 = num() + (rel ? cy : 0)
                let x2 = num() + (rel ? cx : 0), y2 = num() + (rel ? cy : 0)
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.cubic(x1, y1, x2, y2, x, y)); lastC = (x2, y2); lastQ = nil; cx = x; cy = y
            case "S":
                let x1 = lastC.map { 2 * cx - $0.0 } ?? cx, y1 = lastC.map { 2 * cy - $0.1 } ?? cy
                let x2 = num() + (rel ? cx : 0), y2 = num() + (rel ? cy : 0)
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.cubic(x1, y1, x2, y2, x, y)); lastC = (x2, y2); lastQ = nil; cx = x; cy = y
            case "Q":
                let x1 = num() + (rel ? cx : 0), y1 = num() + (rel ? cy : 0)
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.quad(x1, y1, x, y)); lastQ = (x1, y1); lastC = nil; cx = x; cy = y
            case "T":
                let x1 = lastQ.map { 2 * cx - $0.0 } ?? cx, y1 = lastQ.map { 2 * cy - $0.1 } ?? cy
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.quad(x1, y1, x, y)); lastQ = (x1, y1); lastC = nil; cx = x; cy = y
            case "A":
                let rx = num(), ry = num(), rot = num()
                let large = num() != 0, sweep = num() != 0
                let x = num() + (rel ? cx : 0), y = num() + (rel ? cy : 0)
                out.append(.arc(rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep, x: x, y: y)); cx = x; cy = y; lastC = nil; lastQ = nil
            case "Z": out.append(.close); cx = sx; cy = sy; lastC = nil; lastQ = nil
            default: tokens.removeFirst()
            }
        }
        return out
    }

    /// Splits "m5 12 7-7 7 7" / "a1 1 0 012 0" into letters and numbers.
    /// Arc flags are single digits, so after an `A`/`a` the 4th and 5th
    /// numbers are read one character wide.
    static func tokenize(_ d: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var arcArg = -1   // index of the next arc argument when inside an arc command, else -1
        func flush() { if !cur.isEmpty { out.append(cur); cur = ""; if arcArg >= 0 { arcArg = (arcArg + 1) % 7 } } }
        for ch in d {
            if ch.isLetter {
                flush(); out.append(String(ch)); arcArg = (ch == "a" || ch == "A") ? 0 : -1
            } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" {
                flush()
            } else if ch == "-" && !cur.isEmpty && !cur.hasSuffix("e") {
                flush(); cur = "-"
            } else if ch == "." && cur.contains(".") {
                flush(); cur = "."
            } else {
                cur.append(ch)
                if arcArg == 3 || arcArg == 4 { flush() }   // packed flags: "012 0" → "0","1","2 0"
            }
        }
        flush()
        return out
    }
}
