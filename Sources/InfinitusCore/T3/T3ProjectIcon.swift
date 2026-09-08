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
    // text-{color}-600/dark:text-{color}-400 pair. The stops come from
    // `T3TailwindPalette.generated.swift` — the pinned tailwindcss@4.3.3
    // `theme.css` resolved by the generator, NOT v3's `colors.js` hex (v4
    // restated the whole palette in oklch and the sRGB values moved: sky-400
    // is (0, 188, 255) here, #38bdf8 = (56, 189, 248) in v3).
    private static let colorByName: [Name: ColorPair] = [
        .ai: ColorPair(T3Tailwind.violet600, T3Tailwind.violet400),
        .book: ColorPair(T3Tailwind.amber600, T3Tailwind.amber400),
        .braces: ColorPair(T3Tailwind.purple600, T3Tailwind.purple400),
        .circuit: ColorPair(T3Tailwind.teal600, T3Tailwind.teal400),
        .cloud: ColorPair(T3Tailwind.sky600, T3Tailwind.sky400),
        .code: ColorPair(T3Tailwind.blue600, T3Tailwind.blue400),
        .database: ColorPair(T3Tailwind.cyan600, T3Tailwind.cyan400),
        .desktop: ColorPair(T3Tailwind.indigo600, T3Tailwind.indigo400),
        .folderCode: ColorPair(T3Tailwind.orange600, T3Tailwind.orange400),
        .game: ColorPair(T3Tailwind.emerald600, T3Tailwind.emerald400),
        .image: ColorPair(T3Tailwind.pink600, T3Tailwind.pink400),
        .layers: ColorPair(T3Tailwind.fuchsia600, T3Tailwind.fuchsia400),
        .mobile: ColorPair(T3Tailwind.lime600, T3Tailwind.lime400),
        .music: ColorPair(T3Tailwind.fuchsia600, T3Tailwind.fuchsia400),
        .package: ColorPair(T3Tailwind.orange600, T3Tailwind.orange400),
        .security: ColorPair(T3Tailwind.teal600, T3Tailwind.teal400),
        .server: ColorPair(T3Tailwind.blue600, T3Tailwind.blue400),
        .shopping: ColorPair(T3Tailwind.rose600, T3Tailwind.rose400),
        .terminal: ColorPair(T3Tailwind.green600, T3Tailwind.green400),
        .test: ColorPair(T3Tailwind.yellow600, T3Tailwind.yellow400),
        .video: ColorPair(T3Tailwind.red600, T3Tailwind.red400),
        .web: ColorPair(T3Tailwind.sky600, T3Tailwind.sky400),
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
