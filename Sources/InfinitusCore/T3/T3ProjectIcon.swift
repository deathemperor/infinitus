import Foundation

/// Automatic per-project glyph selection: `projectIconModel.ts`'s
/// `selectProjectIcon` (name → one of 22 Lucide icons, scored by keyword
/// match over camelCase/kebab tokens, falling back to a stable hash pick
/// among 5 generic icons) plus `ProjectFavicon.tsx`'s
/// `PROJECT_ICON_COLOR_BY_NAME` and `projectIconColors.ts`'s
/// `PROJECT_ICON_COLORS` (each icon's Tailwind text-color, light/dark).
/// B has no favicon image and no emoji override, so only the automatic
/// Lucide path is ported — `ProjectFavicon.tsx`'s other two branches
/// (`kind: "emoji"`, `kind: "lucide"` override, and the real favicon image)
/// have no B equivalent.
public enum T3ProjectIcon {
    public enum Name: String, Sendable, CaseIterable {
        case ai, book, braces, circuit, cloud, code, database, desktop
        case folderCode = "folder-code"
        case game, image, layers, mobile, music, package, security, server, shopping, terminal, test, video, web
    }

    /// A colour pair, light/dark, as plain 0-255 components — Core has no
    /// dependency on InfinitusUI's `T3RGBA` (Package.swift: InfinitusUI
    /// depends on InfinitusCore, never the reverse), so this stands in for
    /// it; the view converts to `Color` at the call site.
    public struct RGB: Sendable, Equatable {
        public let r, g, b: UInt8
        public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    }

    public struct ColorPair: Sendable, Equatable {
        public let light: RGB
        public let dark: RGB
        public init(_ light: RGB, _ dark: RGB) { self.light = light; self.dark = dark }
    }

    private struct Class { let icon: Name; let terms: [String] }

    // `projectIconModel.ts`'s PROJECT_ICON_MODEL, transcribed verbatim.
    private static let classes: [Class] = [
        Class(icon: .ai, terms: ["ai", "agent", "bot", "gpt", "llm", "ml", "model", "neural"]),
        Class(icon: .mobile, terms: ["android", "expo", "ios", "mobile", "native", "reactnative", "swift"]),
        Class(icon: .desktop, terms: ["desktop", "electron", "linux", "mac", "macos", "tauri", "windows"]),
        Class(icon: .book, terms: ["book", "docs", "documentation", "guide", "handbook", "manual", "wiki"]),
        Class(icon: .security, terms: ["auth", "identity", "oauth", "security", "sso", "vault"]),
        Class(icon: .database, terms: ["analytics", "data", "database", "db", "mongo", "mysql", "postgres", "redis", "sql", "storage"]),
        Class(icon: .cloud, terms: ["aws", "azure", "cloud", "deploy", "devops", "docker", "gcp", "infra", "kubernetes", "terraform"]),
        Class(icon: .server, terms: ["api", "backend", "gateway", "server", "service", "worker"]),
        Class(icon: .terminal, terms: ["automation", "bash", "cli", "command", "script", "shell", "terminal"]),
        Class(icon: .package, terms: ["component", "kit", "lib", "library", "package", "plugin", "sdk", "toolkit"]),
        Class(icon: .test, terms: ["benchmark", "e2e", "fixture", "spec", "test", "testing"]),
        Class(icon: .shopping, terms: ["cart", "commerce", "market", "shop", "store"]),
        Class(icon: .game, terms: ["game", "gaming", "play"]),
        Class(icon: .music, terms: ["audio", "music", "podcast", "radio", "sound"]),
        Class(icon: .video, terms: ["film", "movie", "stream", "video"]),
        Class(icon: .image, terms: ["camera", "gallery", "image", "photo", "picture"]),
        Class(icon: .web, terms: ["browser", "frontend", "nextjs", "react", "site", "svelte", "ui", "vue", "web", "website"]),
    ]

    // `GENERIC_PROJECT_ICONS`, in upstream's order (the stable-hash index
    // below depends on this order and length).
    private static let genericIcons: [Name] = [.code, .braces, .circuit, .folderCode, .layers]

    // `PROJECT_ICON_COLOR_BY_NAME` × `PROJECT_ICON_COLORS`'
    // text-{color}-600/text-{color}-400 pair, resolved to sRGB hex via the
    // pinned tailwindcss@4.3.3 palette (`theme.css`'s oklch stops render to
    // the same sRGB as v3's colors.js at these shades).
    private static let colorByName: [Name: ColorPair] = [
        .ai: ColorPair(RGB(124, 58, 237), RGB(167, 139, 250)),            // violet-600/400
        .book: ColorPair(RGB(217, 119, 6), RGB(251, 191, 36)),            // amber-600/400
        .braces: ColorPair(RGB(147, 51, 234), RGB(192, 132, 252)),        // purple-600/400
        .circuit: ColorPair(RGB(13, 148, 136), RGB(45, 212, 191)),        // teal-600/400
        .cloud: ColorPair(RGB(2, 132, 199), RGB(56, 189, 248)),           // sky-600/400
        .code: ColorPair(RGB(37, 99, 235), RGB(96, 165, 250)),            // blue-600/400
        .database: ColorPair(RGB(8, 145, 178), RGB(34, 211, 238)),        // cyan-600/400
        .desktop: ColorPair(RGB(79, 70, 229), RGB(129, 140, 248)),        // indigo-600/400
        .folderCode: ColorPair(RGB(234, 88, 12), RGB(251, 146, 60)),      // orange-600/400
        .game: ColorPair(RGB(5, 150, 105), RGB(52, 211, 153)),            // emerald-600/400
        .image: ColorPair(RGB(219, 39, 119), RGB(244, 114, 182)),         // pink-600/400
        .layers: ColorPair(RGB(192, 38, 211), RGB(232, 121, 249)),        // fuchsia-600/400
        .mobile: ColorPair(RGB(101, 163, 13), RGB(163, 230, 53)),         // lime-600/400
        .music: ColorPair(RGB(192, 38, 211), RGB(232, 121, 249)),         // fuchsia-600/400
        .package: ColorPair(RGB(234, 88, 12), RGB(251, 146, 60)),         // orange-600/400
        .security: ColorPair(RGB(13, 148, 136), RGB(45, 212, 191)),       // teal-600/400
        .server: ColorPair(RGB(37, 99, 235), RGB(96, 165, 250)),          // blue-600/400
        .shopping: ColorPair(RGB(225, 29, 72), RGB(251, 113, 133)),       // rose-600/400
        .terminal: ColorPair(RGB(22, 163, 74), RGB(74, 222, 128)),        // green-600/400
        .test: ColorPair(RGB(202, 138, 4), RGB(250, 204, 21)),            // yellow-600/400
        .video: ColorPair(RGB(220, 38, 38), RGB(248, 113, 113)),          // red-600/400
        .web: ColorPair(RGB(2, 132, 199), RGB(56, 189, 248)),             // sky-600/400
    ]

    /// `projectNameTokens`: split camelCase, lowercase, then split on
    /// runs of anything that isn't `[a-z0-9]`.
    private static func tokens(_ value: String) -> [String] {
        var spaced = ""
        let chars = Array(value)
        for (i, c) in chars.enumerated() {
            spaced.append(c)
            if i + 1 < chars.count, (c.isLowercase || c.isNumber), chars[i + 1].isUppercase {
                spaced.append(" ")
            }
        }
        var result: [String] = []
        var current = ""
        for c in spaced.lowercased() {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                current.append(c)
            } else if !current.isEmpty {
                result.append(current); current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func termScore(_ token: String, _ term: String) -> Int {
        if token == term { return 3 }
        if term.count >= 4 && (token.hasPrefix(term) || token.hasSuffix(term)) { return 1 }
        return 0
    }

    /// `stableIndex`: FNV-1a-ish 32-bit hash (`Math.imul` wraps the same
    /// way a `UInt32` multiply does) over UTF-16 code units, mod `length`.
    private static func stableIndex(_ value: String, _ length: Int) -> Int {
        var hash: UInt32 = 2_166_136_261
        for unit in value.utf16 {
            hash ^= UInt32(unit)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(length))
    }

    /// `selectProjectIcon`: best keyword-scored class over the project
    /// name's tokens, falling back to a stable per-name pick among the 5
    /// generic icons when nothing scores.
    public static func select(name projectName: String, cwd workspaceRoot: String) -> Name {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if !trimmed.isEmpty {
            name = trimmed
        } else {
            let parts = workspaceRoot.split(whereSeparator: { $0 == "\\" || $0 == "/" })
            name = parts.last(where: { !$0.isEmpty }).map(String.init) ?? "project"
        }
        let cacheKey = name.lowercased()
        let toks = tokens(name)
        var bestIcon: Name?
        var bestScore = 0
        for cls in classes {
            var score = 0
            for token in toks {
                var tokenScore = 0
                for term in cls.terms { tokenScore = max(tokenScore, termScore(token, term)) }
                score += tokenScore
            }
            if score > bestScore { bestIcon = cls.icon; bestScore = score }
        }
        return bestIcon ?? genericIcons[stableIndex(cacheKey, genericIcons.count)]
    }

    public static func color(for name: Name) -> ColorPair { colorByName[name]! }
}
