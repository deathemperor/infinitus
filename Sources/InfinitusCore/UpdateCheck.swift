import Foundation

/// PEP440-lite version ordering, enough for claude-swap's tags
/// ("0.25.0", "0.26.0b1"): release tuples compare first, and a
/// pre-release only loses to the FINAL of its own release — 0.26.0b1
/// still beats 0.25.0. (A naive "any beta < any final" rule would tell
/// a 0.26.0b1 install that 0.25.0 is an upgrade.)
public struct PackageVersion: Comparable, Equatable, Sendable {
    public let release: [Int]
    /// ("b", 1) for "0.26.0b1"; nil for a final release.
    public let pre: (letter: String, number: Int)?

    public init?(_ text: String) {
        var release: [Int] = []
        var pre: (String, Int)? = nil
        var body = Substring(text)
        if let dash = text.firstIndex(of: "-") {
            // "0.4.4-alpha.1" (semver): the dash splits the release from the
            // pre-release marker; letters name it, the trailing digits number it.
            let tail = text[text.index(after: dash)...]
            let letter = tail.prefix(while: { $0.isLetter })
            let digits = tail.drop(while: { !$0.isNumber })
            guard !letter.isEmpty, let num = Int(digits.isEmpty ? "0" : String(digits)) else { return nil }
            pre = (String(letter), num)
            body = text[..<dash]
        }
        for (index, part) in body.split(separator: ".").enumerated() {
            if let n = Int(part) {
                release.append(n)
            } else if index > 0,
                      let match = part.firstIndex(where: { !$0.isNumber }) {
                // "0b1" -> numeric prefix joins the release, suffix is the
                // pre-release marker. Anything unparseable rejects the whole
                // string — a version we can't order must never say "newer".
                guard let head = Int(part[..<match]) else { return nil }
                release.append(head)
                let tail = part[match...]
                let digits = tail.drop(while: { !$0.isNumber })
                guard let num = Int(digits.isEmpty ? "0" : String(digits)) else { return nil }
                pre = (String(tail.prefix(while: { !$0.isNumber })), num)
            } else {
                return nil
            }
        }
        guard !release.isEmpty else { return nil }
        self.release = release
        self.pre = pre
    }

    public static func == (a: PackageVersion, b: PackageVersion) -> Bool {
        !(a < b) && !(b < a)
    }

    public static func < (a: PackageVersion, b: PackageVersion) -> Bool {
        let n = max(a.release.count, b.release.count)
        for i in 0..<n {
            let x = i < a.release.count ? a.release[i] : 0
            let y = i < b.release.count ? b.release[i] : 0
            if x != y { return x < y }
        }
        switch (a.pre, b.pre) {
        case (nil, nil): return false
        case (.some, nil): return true    // 0.26.0b1 < 0.26.0
        case (nil, .some): return false
        case let (.some(p), .some(q)):
            if p.letter != q.letter { return p.letter < q.letter }  // a < b < rc
            return p.number < q.number
        }
    }
}
