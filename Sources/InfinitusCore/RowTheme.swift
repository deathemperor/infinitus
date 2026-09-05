import Foundation

/// One popup row "skin": the vocabulary and colors the account grid renders
/// with. Built-ins ship in code; users add their own via a JSON file (see
/// `customThemesURL`) — same shape, decoded with per-field defaults so a
/// minimal `{"id":"x","name":"X"}` is already a valid (plain-ish) theme.
///
/// Colors are strings — a named SwiftUI color ("red", "purple", …) or
/// "#rrggbb" — mapped to real colors in the app layer, so this type stays
/// UI-framework-free and testable.
public struct RowTheme: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Plain style: text percentages, no gauges (the "Off" look).
    public var plain: Bool
    public var sessionLabel: String
    public var sessionColor: String
    public var weeklyLabel: String
    public var weeklyColor: String
    /// Prepended to the model name in scoped cells ("★ " -> "★ Fable").
    public var scopedPrefix: String
    public var scopedColor: String
    public var creditLabel: String
    public var creditColor: String
    /// Leading icon for the estimated-spend cell ("💰1,131").
    public var cashIcon: String
    /// "sf:<symbol>" for an SF Symbol, anything else renders as text/emoji.
    public var aheadIcon: String
    public var deadMarker: String
    /// Prepended to an exhausted window's reset label ("🧪 29m (21:00)").
    public var revivePrefix: String
    /// Verb for a dead limit: "MP down", "🎬 sold out", "LIFE MIA". The
    /// tooltip always carries the plain-English explanation.
    public var deadVerb: String
    /// The all-fresh row's word ("✓ ready"); plain themes keep "ready".
    public var readyLabel: String
    /// Tint for the switch celebration and data-change glow; "" means the
    /// app accent color.
    public var flashColor: String
    /// Per-model rename ("Fable" -> "Dragon"); unmapped models keep their
    /// real name. Tooltips always carry the real name.
    public var modelAlias: [String: String]
    /// Replaces the "Max " in plan strings ("Max 20x" -> "Lv 20x").
    /// "" keeps the plan verbatim.
    public var planPrefix: String
    /// Prepended to the account number ("P" -> "P1").
    public var slotPrefix: String
    /// The live "resetting…" word while a window rolls over
    /// ("respawning…", "recompiling…"); "" keeps "resetting…".
    public var resetWord: String
    /// Next-candidate marker ("🎬" next movie, "▶" plain). "" keeps the
    /// green triangle.
    public var nextIcon: String
    /// Active-account marker — replaces the slot text on the account
    /// currently in use ("👑" instead of "P1"). "" keeps the slot text.
    public var activeIcon: String
    /// Session status words on the phone's lists, keyed by the engine's
    /// raw status ("busy", "waiting", "idle", "shell"); missing keys keep
    /// the plain words (user 2026-09-04: "theme the listing and its
    /// words too: working, idle").
    public var sessionWords: [String: String]
    /// Phone tab bar, keyed "sessions" / "fleet" / "settings": the label
    /// and the icon ("sf:<symbol>" or an emoji). Missing keys keep the
    /// plain tab.
    public var tabLabels: [String: String]
    public var tabIcons: [String: String]
    /// The theme's pool of account names — single alias-safe tokens
    /// (letters, digits, `.`, `-`, `_`) the Randomize-names action
    /// draws from (user 2026-09-04: "the set of random names must be
    /// from the supported themes"). Empty on Off and on custom themes
    /// that don't define one; the picker then draws from every built-in.
    public var accountNames: [String]
    /// The phone's placeholder copy, keyed "loading" (a feed on its
    /// way), "empty" (a feed with nothing in it), "noSessions" (the
    /// list with nothing live) and "searching" (no Mac reachable yet);
    /// missing keys keep the plain words (user 2026-09-05: "themify the
    /// loading texts, animation, icons too").
    public var loadingWords: [String: String]
    /// The icon those placeholders show ("sf:<symbol>" or an emoji) and
    /// how it moves: "spin", "pulse", "bounce" or "flicker". Empty keeps
    /// the system spinner.
    public var loadingIcon: String
    public var loadingMotion: String

    public init(
        id: String, name: String, plain: Bool = false,
        sessionLabel: String = "5h", sessionColor: String = "blue",
        weeklyLabel: String = "7d", weeklyColor: String = "red",
        scopedPrefix: String = "", scopedColor: String = "purple",
        creditLabel: String = "$", creditColor: String = "green",
        cashIcon: String = "💰", aheadIcon: String = "sf:flame.fill",
        deadMarker: String = "💀", revivePrefix: String = "",
        deadVerb: String = "out", readyLabel: String = "ready",
        flashColor: String = "",
        modelAlias: [String: String] = [:],
        planPrefix: String = "",
        slotPrefix: String = "",
        resetWord: String = "",
        nextIcon: String = "", activeIcon: String = "",
        sessionWords: [String: String] = [:],
        tabLabels: [String: String] = [:], tabIcons: [String: String] = [:],
        accountNames: [String] = [],
        loadingWords: [String: String] = [:],
        loadingIcon: String = "", loadingMotion: String = ""
    ) {
        self.id = id
        self.name = name
        self.plain = plain
        self.sessionLabel = sessionLabel
        self.sessionColor = sessionColor
        self.weeklyLabel = weeklyLabel
        self.weeklyColor = weeklyColor
        self.scopedPrefix = scopedPrefix
        self.scopedColor = scopedColor
        self.creditLabel = creditLabel
        self.creditColor = creditColor
        self.cashIcon = cashIcon
        self.aheadIcon = aheadIcon
        self.deadMarker = deadMarker
        self.revivePrefix = revivePrefix
        self.deadVerb = deadVerb
        self.readyLabel = readyLabel
        self.flashColor = flashColor
        self.modelAlias = modelAlias
        self.planPrefix = planPrefix
        self.slotPrefix = slotPrefix
        self.resetWord = resetWord
        self.nextIcon = nextIcon
        self.activeIcon = activeIcon
        self.sessionWords = sessionWords
        self.tabLabels = tabLabels
        self.tabIcons = tabIcons
        self.accountNames = accountNames
        self.loadingWords = loadingWords
        self.loadingIcon = loadingIcon
        self.loadingMotion = loadingMotion
    }

    public static let plainSessionWords = [
        "busy": "Working", "waiting": "Waiting on you", "idle": "Idle", "shell": "At the shell",
    ]
    public static let plainLoadingWords = [
        "loading": "Loading…", "empty": "Nothing here yet",
        "noSessions": "No live sessions", "searching": "Looking for the Mac…",
        // The chat composer's placeholder, typing and dictating (#124).
        "composerReply": "Reply…", "composerListening": "Listening…",
    ]
    public static let plainTabLabels = ["sessions": "Sessions", "fleet": "Fleet", "settings": "Settings"]
    public static let plainTabIcons = [
        "sessions": "sf:brain", "fleet": "sf:gauge.with.dots.needle.67percent", "settings": "sf:gearshape",
    ]

    /// The themed status word; unknown statuses capitalise the raw one.
    public func sessionWord(_ status: String) -> String {
        if let w = sessionWords[status] ?? Self.plainSessionWords[status] { return w }
        return status.isEmpty ? "Unknown" : status.prefix(1).uppercased() + status.dropFirst()
    }
    public func tabLabel(_ tab: String) -> String { tabLabels[tab] ?? Self.plainTabLabels[tab] ?? tab }
    public func tabIcon(_ tab: String) -> String { tabIcons[tab] ?? Self.plainTabIcons[tab] ?? "sf:circle" }
    public func loadingWord(_ key: String) -> String { loadingWords[key] ?? Self.plainLoadingWords[key] ?? key }

    /// Theme name for a model ("Fable" -> "Dragon"); real name otherwise.
    public func modelName(_ name: String?) -> String {
        guard let name else { return "?" }
        return modelAlias[name] ?? name
    }

    /// Themed plan text: "Max 20x" -> planPrefix + "20x".
    public func planLabel(_ plan: String, compact: Bool) -> String {
        let tier = plan.replacingOccurrences(of: "Max ", with: "")
            .replacingOccurrences(of: "Enterprise", with: compact ? "Ent" : "Enterprise")
        if planPrefix.isEmpty { return compact ? tier : plan }
        return planPrefix + tier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = RowTheme(id: try c.decode(String.self, forKey: .id),
                            name: try c.decode(String.self, forKey: .name))
        self.init(
            id: base.id, name: base.name,
            plain: try c.decodeIfPresent(Bool.self, forKey: .plain) ?? false,
            sessionLabel: try c.decodeIfPresent(String.self, forKey: .sessionLabel) ?? base.sessionLabel,
            sessionColor: try c.decodeIfPresent(String.self, forKey: .sessionColor) ?? base.sessionColor,
            weeklyLabel: try c.decodeIfPresent(String.self, forKey: .weeklyLabel) ?? base.weeklyLabel,
            weeklyColor: try c.decodeIfPresent(String.self, forKey: .weeklyColor) ?? base.weeklyColor,
            scopedPrefix: try c.decodeIfPresent(String.self, forKey: .scopedPrefix) ?? base.scopedPrefix,
            scopedColor: try c.decodeIfPresent(String.self, forKey: .scopedColor) ?? base.scopedColor,
            creditLabel: try c.decodeIfPresent(String.self, forKey: .creditLabel) ?? base.creditLabel,
            creditColor: try c.decodeIfPresent(String.self, forKey: .creditColor) ?? base.creditColor,
            cashIcon: try c.decodeIfPresent(String.self, forKey: .cashIcon) ?? base.cashIcon,
            aheadIcon: try c.decodeIfPresent(String.self, forKey: .aheadIcon) ?? base.aheadIcon,
            deadMarker: try c.decodeIfPresent(String.self, forKey: .deadMarker) ?? base.deadMarker,
            revivePrefix: try c.decodeIfPresent(String.self, forKey: .revivePrefix) ?? base.revivePrefix,
            deadVerb: try c.decodeIfPresent(String.self, forKey: .deadVerb) ?? base.deadVerb,
            readyLabel: try c.decodeIfPresent(String.self, forKey: .readyLabel) ?? base.readyLabel,
            flashColor: try c.decodeIfPresent(String.self, forKey: .flashColor) ?? base.flashColor,
            modelAlias: try c.decodeIfPresent([String: String].self, forKey: .modelAlias) ?? base.modelAlias,
            planPrefix: try c.decodeIfPresent(String.self, forKey: .planPrefix) ?? base.planPrefix,
            slotPrefix: try c.decodeIfPresent(String.self, forKey: .slotPrefix) ?? base.slotPrefix,
            resetWord: try c.decodeIfPresent(String.self, forKey: .resetWord) ?? base.resetWord,
            nextIcon: try c.decodeIfPresent(String.self, forKey: .nextIcon) ?? base.nextIcon,
            activeIcon: try c.decodeIfPresent(String.self, forKey: .activeIcon) ?? base.activeIcon,
            sessionWords: try c.decodeIfPresent([String: String].self, forKey: .sessionWords) ?? [:],
            tabLabels: try c.decodeIfPresent([String: String].self, forKey: .tabLabels) ?? [:],
            tabIcons: try c.decodeIfPresent([String: String].self, forKey: .tabIcons) ?? [:],
            accountNames: try c.decodeIfPresent([String].self, forKey: .accountNames) ?? [],
            loadingWords: try c.decodeIfPresent([String: String].self, forKey: .loadingWords) ?? [:],
            loadingIcon: try c.decodeIfPresent(String.self, forKey: .loadingIcon) ?? "",
            loadingMotion: try c.decodeIfPresent(String.self, forKey: .loadingMotion) ?? ""
        )
    }

    // MARK: random account names

    /// Alias-safe: what `cswap alias` accepts — letters, digits, `.`,
    /// `-`, `_`, not purely numeric.
    public static func isAliasSafe(_ name: String) -> Bool {
        guard !name.isEmpty, !name.allSatisfy(\.isNumber) else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) || "._-".unicodeScalars.contains($0)) }
    }

    /// `count` distinct names for a fleet, from this theme's pool (every
    /// built-in's when it has none), never one in `taken` — the names the
    /// fleet already wears when a single account re-rolls (#145). Past
    /// the pool, names repeat with a numeric suffix. Deterministic under
    /// `generator` for tests.
    public func randomAccountNames<G: RandomNumberGenerator>(count: Int, avoiding taken: Set<String> = [],
                                                             using generator: inout G) -> [String] {
        var pool = accountNames.isEmpty ? Self.builtins.flatMap(\.accountNames) : accountNames
        pool = Array(Set(pool)).sorted().shuffled(using: &generator)
        guard !pool.isEmpty, count > 0 else { return [] }
        var picks: [String] = []
        var level = 1
        while picks.count < count {
            for name in pool where picks.count < count {
                let candidate = level == 1 ? name : "\(name)-\(level)"
                if !taken.contains(candidate) { picks.append(candidate) }
            }
            level += 1
        }
        return picks
    }

    public func randomAccountNames(count: Int, avoiding taken: Set<String> = []) -> [String] {
        var g = SystemRandomNumberGenerator()
        return randomAccountNames(count: count, avoiding: taken, using: &g)
    }

    // MARK: built-ins

    public static let off = RowTheme(
        id: "off", name: "Off — plain numbers", plain: true,
        sessionLabel: "5h", sessionColor: "secondary",
        weeklyLabel: "7d", weeklyColor: "secondary",
        deadMarker: "\u{2715}")   // plain ✕ — the 💀 belongs to the skins (user 2026-08-30)

    public static let rpg = RowTheme(
        id: "rpg", name: "RPG — HP/MP gauges + gold",
        sessionLabel: "MP", sessionColor: "blue",
        weeklyLabel: "HP", weeklyColor: "red",
        scopedPrefix: "⚔ ", scopedColor: "purple",
        creditLabel: "$", creditColor: "green",
        cashIcon: "💰", aheadIcon: "sf:flame.circle.fill",
        deadMarker: "💀", revivePrefix: "🧪 ", deadVerb: "down",
        readyLabel: "full HP", flashColor: "yellow",
        modelAlias: ["Fable": "Dragon", "Opus": "Golem",
                     "Sonnet": "Bard", "Haiku": "Imp"],
        planPrefix: "Lv ", slotPrefix: "P", resetWord: "respawning…", nextIcon: "🎲", activeIcon: "👑",
        sessionWords: ["busy": "Questing", "waiting": "Awaiting orders", "idle": "Resting at camp", "shell": "In the forge"],
        tabLabels: ["sessions": "Quests", "fleet": "Party", "settings": "Inventory"],
        tabIcons: ["sessions": "sf:scroll", "fleet": "sf:person.3.fill", "settings": "sf:bag.fill"],
        accountNames: ["Paladin", "Ranger", "Rogue", "Cleric", "Wizard", "Warlock", "Druid", "Monk", "Knight", "Archer", "Sorcerer", "Barbarian", "Alchemist", "Sentinel", "Necromancer", "Bard"],
        loadingWords: ["loading": "Rolling initiative…", "empty": "The quest log is blank", "noSessions": "No quests underway", "searching": "Scouting for the Mac…", "composerReply": "Give your orders…", "composerListening": "Hearing you…"],
        loadingIcon: "sf:dice.fill", loadingMotion: "spin")

    public static let movie = RowTheme(
        id: "movie", name: "Movie — reels & box office",
        sessionLabel: "🎥", sessionColor: "yellow",
        weeklyLabel: "🎞", weeklyColor: "indigo",
        scopedPrefix: "★ ", scopedColor: "orange",
        creditLabel: "🎟", creditColor: "green",
        cashIcon: "💵", aheadIcon: "sf:speedometer",
        deadMarker: "🔚", revivePrefix: "re-release ", deadVerb: "sold out",
        readyLabel: "now showing", flashColor: "orange",
        modelAlias: ["Fable": "Epic", "Opus": "Blockbuster",
                     "Sonnet": "Indie", "Haiku": "Short"],
        planPrefix: "Studio ", slotPrefix: "🎬", resetWord: "premiering…", nextIcon: "🍿", activeIcon: "🌟",
        sessionWords: ["busy": "Rolling", "waiting": "Waiting for the cue", "idle": "Intermission", "shell": "Backstage"],
        tabLabels: ["sessions": "Scenes", "fleet": "Cast", "settings": "Studio"],
        tabIcons: ["sessions": "sf:film", "fleet": "sf:person.3.fill", "settings": "sf:slider.horizontal.3"],
        accountNames: ["Director", "Producer", "Stuntman", "Cameo", "Montage", "Premiere", "Sequel", "Matinee", "Blockbuster", "Cliffhanger", "Trailer", "Voiceover", "Screenplay", "Boxoffice", "Redcarpet", "Cutscene"],
        loadingWords: ["loading": "Rolling film…", "empty": "Nothing on the reel yet", "noSessions": "No reels rolling", "searching": "Finding the projector…", "composerReply": "Feed the actor a line…", "composerListening": "Rolling sound…"],
        loadingIcon: "sf:film", loadingMotion: "spin")

    public static let hades = RowTheme(
        id: "hades", name: "Hades — blades & darkness",
        sessionLabel: "🗡", sessionColor: "red",
        weeklyLabel: "🔱", weeklyColor: "purple",
        scopedPrefix: "🏛 ", scopedColor: "teal",
        creditLabel: "🪙", creditColor: "yellow",
        cashIcon: "💠", aheadIcon: "🔥",
        deadMarker: "☠", revivePrefix: "🩸 ", deadVerb: "fallen",
        readyLabel: "unscathed", flashColor: "red",
        modelAlias: ["Fable": "Hydra", "Opus": "Cerberus",
                     "Sonnet": "Fury", "Haiku": "Shade"],
        planPrefix: "Heat ", slotPrefix: "†", resetWord: "raising the dead…", nextIcon: "🕯", activeIcon: "🌿",
        sessionWords: ["busy": "Fighting", "waiting": "Awaiting the call", "idle": "In the lounge", "shell": "At the forge"],
        tabLabels: ["sessions": "Runs", "fleet": "Pantheon", "settings": "Mirror"],
        tabIcons: ["sessions": "sf:flame", "fleet": "sf:person.3.fill", "settings": "sf:sparkles"],
        accountNames: ["Zagreus", "Megaera", "Thanatos", "Cerberus", "Nyx", "Chaos", "Charon", "Hypnos", "Achilles", "Patroclus", "Orpheus", "Eurydice", "Sisyphus", "Dusa", "Skelly", "Hermes"],
        loadingWords: ["loading": "Crossing the Styx…", "empty": "The river is still", "noSessions": "No fights underway", "searching": "Calling for Charon…", "composerReply": "Command the shade…", "composerListening": "Listening from the depths…"],
        loadingIcon: "sf:flame.fill", loadingMotion: "flicker")

    public static let mgs = RowTheme(
        id: "mgs", name: "Metal Gear — tactical espionage",
        sessionLabel: "LIFE", sessionColor: "green",
        weeklyLabel: "PSY", weeklyColor: "cyan",
        scopedPrefix: "⚠ ", scopedColor: "yellow",
        creditLabel: "📦", creditColor: "green",
        cashIcon: "GMP ", aheadIcon: "❗",
        deadMarker: "☠", revivePrefix: "💊 ", deadVerb: "MIA",
        readyLabel: "all clear", flashColor: "green",
        modelAlias: ["Fable": "FOXHOUND", "Opus": "REX",
                     "Sonnet": "RAY", "Haiku": "Mk.II"],
        planPrefix: "Rank ", slotPrefix: "S", resetWord: "extraction inbound…", nextIcon: "🎯", activeIcon: "🐍",
        sessionWords: ["busy": "On mission", "waiting": "Awaiting orders", "idle": "In the box", "shell": "At the armory"],
        tabLabels: ["sessions": "Missions", "fleet": "Squad", "settings": "Codec"],
        tabIcons: ["sessions": "sf:target", "fleet": "sf:person.3.fill", "settings": "sf:antenna.radiowaves.left.and.right"],
        accountNames: ["Snake", "Otacon", "Raiden", "Ocelot", "Meryl", "Gray-Fox", "Sniper-Wolf", "Psycho-Mantis", "Vulcan-Raven", "Liquid", "Solidus", "Big-Boss", "Campbell", "Naomi", "Mei-Ling", "Kaz"],
        loadingWords: ["loading": "Establishing codec link…", "empty": "No intel yet", "noSessions": "No missions active", "searching": "Contacting HQ…", "composerReply": "Radio the operative…", "composerListening": "Codec open…"],
        loadingIcon: "sf:antenna.radiowaves.left.and.right", loadingMotion: "flicker")

    public static let agent = RowTheme(
        id: "agent", name: "AI Agentic — tokens & context",
        sessionLabel: "CTX", sessionColor: "cyan",
        weeklyLabel: "TOK", weeklyColor: "purple",
        scopedPrefix: "🤖 ", scopedColor: "mint",
        creditLabel: "⚡", creditColor: "orange",
        cashIcon: "🪙", aheadIcon: "sf:sparkles",
        deadMarker: "🔌", revivePrefix: "🔁 ", deadVerb: "rate-limited",
        readyLabel: "ready to ship", flashColor: "cyan",
        modelAlias: ["Fable": "frontier", "Opus": "opus-4",
                     "Sonnet": "sonnet-4", "Haiku": "haiku-4"],
        planPrefix: "tier-", slotPrefix: "agent-", resetWord: "rate limit lifting…", nextIcon: "⏭", activeIcon: "🧠",
        sessionWords: ["busy": "Reasoning", "waiting": "Blocked on a human", "idle": "Idle", "shell": "In the shell"],
        tabLabels: ["sessions": "Agents", "fleet": "Providers", "settings": "Config"],
        tabIcons: ["sessions": "sf:cpu", "fleet": "sf:server.rack", "settings": "sf:gearshape"],
        accountNames: ["Planner", "Executor", "Router", "Retriever", "Critic", "Verifier", "Summarizer", "Orchestrator", "Scout", "Worker", "Reviewer", "Indexer", "Sampler", "Toolsmith", "Tokenizer", "Grader"],
        loadingWords: ["loading": "Streaming tokens…", "empty": "Empty context", "noSessions": "No agents running", "searching": "Resolving the Mac…", "composerReply": "Prompt the agent…", "composerListening": "Transcribing…"],
        loadingIcon: "sf:cpu", loadingMotion: "pulse")

    public static let swe = RowTheme(
        id: "swe", name: "Classic SWE — hand-written, no AI",
        sessionLabel: "☕", sessionColor: "orange",
        weeklyLabel: "🗓", weeklyColor: "blue",
        scopedPrefix: "📐 ", scopedColor: "teal",
        creditLabel: "LOC", creditColor: "green",
        cashIcon: "💾", aheadIcon: "sf:flame.fill",
        deadMarker: "🐛", revivePrefix: "hotfix ", deadVerb: "segfaulted",
        readyLabel: "compiles clean", flashColor: "blue",
        modelAlias: ["Fable": "mainframe", "Opus": "kernel",
                     "Sonnet": "daemon", "Haiku": "script"],
        planPrefix: "v", slotPrefix: "#", resetWord: "recompiling…", nextIcon: "⏭", activeIcon: "⌨️",
        sessionWords: ["busy": "Coding", "waiting": "Needs review", "idle": "Idle", "shell": "At the terminal"],
        tabLabels: ["sessions": "Tickets", "fleet": "Team", "settings": "Preferences"],
        tabIcons: ["sessions": "sf:ticket", "fleet": "sf:person.3.fill", "settings": "sf:gearshape"],
        accountNames: ["Compiler", "Linker", "Debugger", "Kernel", "Daemon", "Pointer", "Mutex", "Segfault", "Bytecode", "Makefile", "Heap", "Stack", "Register", "Opcode", "Syscall", "Refactor"],
        loadingWords: ["loading": "Compiling…", "empty": "Empty log", "noSessions": "No builds running", "searching": "Pinging the Mac…", "composerReply": "Write the ticket…", "composerListening": "Taking dictation…"],
        loadingIcon: "sf:terminal", loadingMotion: "pulse")

    public static let scifi = RowTheme(
        id: "scifi", name: "Sci-Fi — warp cores & shields",
        sessionLabel: "PWR", sessionColor: "blue",
        weeklyLabel: "SHLD", weeklyColor: "teal",
        scopedPrefix: "🛸 ", scopedColor: "mint",
        creditLabel: "🔋", creditColor: "green",
        cashIcon: "🪐", aheadIcon: "☄",
        deadMarker: "💥", revivePrefix: "🔧 ", deadVerb: "offline",
        readyLabel: "all systems go", flashColor: "cyan",
        modelAlias: ["Fable": "Mothership", "Opus": "Cruiser",
                     "Sonnet": "Fighter", "Haiku": "Probe"],
        planPrefix: "Class ", slotPrefix: "🚀", resetWord: "recharging…", nextIcon: "📡", activeIcon: "🧑\u{200D}🚀",
        sessionWords: ["busy": "Warping", "waiting": "Awaiting command", "idle": "Docked", "shell": "In engineering"],
        tabLabels: ["sessions": "Missions", "fleet": "Fleet", "settings": "Bridge"],
        tabIcons: ["sessions": "sf:scope", "fleet": "sf:airplane", "settings": "sf:slider.horizontal.3"],
        accountNames: ["Nebula", "Warpcore", "Photon", "Andromeda", "Quasar", "Deflector", "Hyperdrive", "Replicator", "Tachyon", "Starboard", "Airlock", "Cryopod", "Phaser", "Nacelle", "Wormhole", "Singularity"],
        loadingWords: ["loading": "Charging the warp core…", "empty": "No transmissions yet", "noSessions": "No ships underway", "searching": "Hailing the Mac…", "composerReply": "Hail the ship…", "composerListening": "Comms open…"],
        loadingIcon: "sf:atom", loadingMotion: "spin")

    public static let west = RowTheme(
        id: "west", name: "Wild West — six-guns & gold rush",
        sessionLabel: "🔫", sessionColor: "orange",
        weeklyLabel: "🐴", weeklyColor: "brown",
        scopedPrefix: "🤠 ", scopedColor: "yellow",
        creditLabel: "🏦", creditColor: "green",
        cashIcon: "🥇", aheadIcon: "💨",
        deadMarker: "🪦", revivePrefix: "🌅 ", deadVerb: "six feet under",
        readyLabel: "saddled up", flashColor: "orange",
        modelAlias: ["Fable": "Outlaw", "Opus": "Sheriff",
                     "Sonnet": "Deputy", "Haiku": "Tumbleweed"],
        planPrefix: "Bounty ", slotPrefix: "⭐", resetWord: "sun's rising…", nextIcon: "🌵", activeIcon: "🏇",
        sessionWords: ["busy": "Riding", "waiting": "At the saloon", "idle": "Camped", "shell": "At the smithy"],
        tabLabels: ["sessions": "Posses", "fleet": "Ranch", "settings": "Saddlebag"],
        tabIcons: ["sessions": "sf:hare", "fleet": "sf:house", "settings": "sf:bag"],
        accountNames: ["Sheriff", "Outlaw", "Marshal", "Deputy", "Wrangler", "Gunslinger", "Prospector", "Bandit", "Drifter", "Rancher", "Saloon", "Stagecoach", "Tumbleweed", "Maverick", "Bronco", "Mustang"],
        loadingWords: ["loading": "Saddling up…", "empty": "Tumbleweeds only", "noSessions": "Nobody's riding", "searching": "Tracking the Mac…", "composerReply": "Send word…", "composerListening": "Ears open…"],
        loadingIcon: "sf:sun.max.fill", loadingMotion: "spin")

    public static let cyber = RowTheme(
        id: "cyber", name: "Cyberpunk — chrome & neon",
        sessionLabel: "RAM", sessionColor: "#ff2d95",
        weeklyLabel: "NET", weeklyColor: "yellow",
        scopedPrefix: "🦾 ", scopedColor: "cyan",
        creditLabel: "💳", creditColor: "green",
        cashIcon: "💴", aheadIcon: "🧨",
        deadMarker: "💀", revivePrefix: "🧬 ", deadVerb: "flatlined",
        readyLabel: "jacked in", flashColor: "#ff2d95",
        modelAlias: ["Fable": "Netrunner", "Opus": "Militech",
                     "Sonnet": "Ripperdoc", "Haiku": "Gonk"],
        planPrefix: "Cred ", slotPrefix: "◢", resetWord: "rebooting…", nextIcon: "🕶", activeIcon: "⚡",
        sessionWords: ["busy": "Jacked in", "waiting": "Awaiting handshake", "idle": "Idle", "shell": "In the terminal"],
        tabLabels: ["sessions": "Runs", "fleet": "Rig", "settings": "Deck"],
        tabIcons: ["sessions": "sf:bolt", "fleet": "sf:cpu", "settings": "sf:slider.horizontal.3"],
        accountNames: ["Netrunner", "Chrome", "Neon", "Glitch", "Static", "Proxy", "Cipher", "Ghost", "Wetware", "Blackice", "Datajack", "Overclock", "Synth", "Mainframe", "Firewall", "Zero-Day"],
        loadingWords: ["loading": "Jacking in…", "empty": "Empty buffer", "noSessions": "No runs active", "searching": "Scanning for the Mac…", "composerReply": "Jack a message in…", "composerListening": "Mic hot…"],
        loadingIcon: "sf:bolt.fill", loadingMotion: "flicker")

    public static let gothic = RowTheme(
        id: "gothic", name: "Gothic — candles & cathedrals",
        sessionLabel: "🦇", sessionColor: "purple",
        weeklyLabel: "🌙", weeklyColor: "indigo",
        scopedPrefix: "⛪ ", scopedColor: "gray",
        creditLabel: "🗝", creditColor: "yellow",
        cashIcon: "⚱", aheadIcon: "🔮",
        deadMarker: "⚰️", revivePrefix: "🌒 ", deadVerb: "entombed",
        readyLabel: "immortal", flashColor: "purple",
        modelAlias: ["Fable": "Vampire Lord", "Opus": "Gargoyle",
                     "Sonnet": "Wraith", "Haiku": "Ghoul"],
        planPrefix: "Crypt ", slotPrefix: "✟", resetWord: "tolling midnight…", nextIcon: "🌹", activeIcon: "🕯",
        sessionWords: ["busy": "Chanting", "waiting": "Awaiting confession", "idle": "At rest", "shell": "In the crypt"],
        tabLabels: ["sessions": "Rites", "fleet": "Coven", "settings": "Sacristy"],
        tabIcons: ["sessions": "sf:flame", "fleet": "sf:person.3.fill", "settings": "sf:gearshape"],
        accountNames: ["Raven", "Belfry", "Gargoyle", "Candle", "Crypt", "Requiem", "Cathedral", "Vesper", "Nocturne", "Wraith", "Ember", "Sepulcher", "Lantern", "Moth", "Thorn", "Abbey"],
        loadingWords: ["loading": "Lighting the candles…", "empty": "The nave is silent", "noSessions": "No rites tonight", "searching": "Listening for the bell…", "composerReply": "Whisper to the acolyte…", "composerListening": "The walls listen…"],
        loadingIcon: "sf:flame", loadingMotion: "flicker")

    public static let musical = RowTheme(
        id: "musical", name: "Musical — tempo & encores",
        sessionLabel: "🎵", sessionColor: "indigo",
        weeklyLabel: "🎼", weeklyColor: "purple",
        scopedPrefix: "🎤 ", scopedColor: "orange",
        creditLabel: "🎫", creditColor: "green",
        cashIcon: "💿", aheadIcon: "sf:metronome",
        deadMarker: "🔇", revivePrefix: "encore ", deadVerb: "gone quiet",
        readyLabel: "in tune", flashColor: "purple",
        modelAlias: ["Fable": "Maestro", "Opus": "Opera",
                     "Sonnet": "Sonata", "Haiku": "Jingle"],
        planPrefix: "Act ", slotPrefix: "♪", resetWord: "tuning up…", nextIcon: "🎻", activeIcon: "🎷",
        sessionWords: ["busy": "Performing", "waiting": "Awaiting the conductor", "idle": "Between sets", "shell": "Tuning"],
        tabLabels: ["sessions": "Sets", "fleet": "Ensemble", "settings": "Mixer"],
        tabIcons: ["sessions": "sf:music.note.list", "fleet": "sf:person.3.fill", "settings": "sf:slider.horizontal.3"],
        accountNames: ["Overture", "Encore", "Tempo", "Crescendo", "Allegro", "Sonata", "Cadenza", "Aria", "Rondo", "Fugue", "Prelude", "Finale", "Vibrato", "Staccato", "Maestro", "Coda"],
        loadingWords: ["loading": "Tuning the orchestra…", "empty": "An empty score", "noSessions": "No sets playing", "searching": "Finding the conductor…", "composerReply": "Cue the next line…", "composerListening": "Mic's live…"],
        loadingIcon: "sf:music.note", loadingMotion: "bounce")

    public static let earth = RowTheme(
        id: "earth", name: "Planet Earth — wild documentary",
        sessionLabel: "🐆", sessionColor: "orange",
        weeklyLabel: "🌳", weeklyColor: "green",
        scopedPrefix: "🦅 ", scopedColor: "teal",
        creditLabel: "🍃", creditColor: "mint",
        cashIcon: "🌰", aheadIcon: "🌋",
        deadMarker: "🦴", revivePrefix: "🌱 ", deadVerb: "extinct",
        readyLabel: "thriving", flashColor: "green",
        modelAlias: ["Fable": "Blue Whale", "Opus": "Elephant",
                     "Sonnet": "Wolf", "Haiku": "Hummingbird"],
        planPrefix: "Biome ", slotPrefix: "🐾", resetWord: "migrating…", nextIcon: "🦋", activeIcon: "🦁",
        sessionWords: ["busy": "Hunting", "waiting": "Waiting for the herd", "idle": "Grazing", "shell": "Burrowing"],
        tabLabels: ["sessions": "Herds", "fleet": "Habitat", "settings": "Field notes"],
        tabIcons: ["sessions": "sf:leaf", "fleet": "sf:globe.americas", "settings": "sf:book"],
        accountNames: ["Falcon", "Orca", "Panther", "Condor", "Wolf", "Otter", "Lynx", "Heron", "Bison", "Jaguar", "Puffin", "Gecko", "Mantis", "Ibex", "Marlin", "Osprey"],
        loadingWords: ["loading": "Tracking the herd…", "empty": "Nothing stirs", "noSessions": "No hunts underway", "searching": "Following the migration…", "composerReply": "Call to the herd…", "composerListening": "Ears pricked…"],
        loadingIcon: "sf:leaf.fill", loadingMotion: "bounce")

    public static let cosmo = RowTheme(
        id: "cosmo", name: "Cosmos — stars & black holes",
        sessionLabel: "☀", sessionColor: "yellow",
        weeklyLabel: "🌌", weeklyColor: "purple",
        scopedPrefix: "🌠 ", scopedColor: "indigo",
        creditLabel: "💫", creditColor: "cyan",
        cashIcon: "🌕", aheadIcon: "🌀",
        deadMarker: "🕳", revivePrefix: "✨ ", deadVerb: "collapsed",
        readyLabel: "shining", flashColor: "indigo",
        modelAlias: ["Fable": "Galaxy", "Opus": "Supernova",
                     "Sonnet": "Nebula", "Haiku": "Comet"],
        planPrefix: "Orbit ", slotPrefix: "✦", resetWord: "orbiting back…", nextIcon: "🔭", activeIcon: "🪐",
        sessionWords: ["busy": "Orbiting", "waiting": "Awaiting ground control", "idle": "Drifting", "shell": "In the airlock"],
        tabLabels: ["sessions": "Missions", "fleet": "Constellation", "settings": "Mission control"],
        tabIcons: ["sessions": "sf:moon.stars", "fleet": "sf:sparkles", "settings": "sf:gearshape"],
        accountNames: ["Andromeda", "Orion", "Vega", "Sirius", "Pulsar", "Quasar", "Cassiopeia", "Lyra", "Altair", "Rigel", "Antares", "Polaris", "Kepler", "Halley", "Titan", "Europa"],
        loadingWords: ["loading": "Aligning the telescope…", "empty": "Empty sky", "noSessions": "No orbits active", "searching": "Calling ground control…", "composerReply": "Signal the crew…", "composerListening": "Ground control listening…"],
        loadingIcon: "sf:sparkles", loadingMotion: "pulse")

    public static let ocean = RowTheme(
        id: "ocean", name: "Ocean — tides & deep water",
        sessionLabel: "🌊", sessionColor: "blue",
        weeklyLabel: "🐋", weeklyColor: "teal",
        scopedPrefix: "🐠 ", scopedColor: "cyan",
        creditLabel: "🐚", creditColor: "mint",
        cashIcon: "🦪", aheadIcon: "🦈",
        deadMarker: "⚓", revivePrefix: "🫧 ", deadVerb: "sunk",
        readyLabel: "smooth sailing", flashColor: "teal",
        modelAlias: ["Fable": "Leviathan", "Opus": "Orca",
                     "Sonnet": "Dolphin", "Haiku": "Minnow"],
        planPrefix: "Depth ", slotPrefix: "🪸", resetWord: "tide turning…", nextIcon: "🐬", activeIcon: "⛵",
        sessionWords: ["busy": "Diving", "waiting": "Surfacing", "idle": "Adrift", "shell": "In the hold"],
        tabLabels: ["sessions": "Voyages", "fleet": "Fleet", "settings": "Galley"],
        tabIcons: ["sessions": "sf:water.waves", "fleet": "sf:sailboat", "settings": "sf:gearshape"],
        accountNames: ["Tide", "Kelp", "Coral", "Nautilus", "Abyss", "Trench", "Reef", "Kraken", "Manta", "Narwhal", "Lagoon", "Riptide", "Anchor", "Seafoam", "Marlin", "Barnacle"],
        loadingWords: ["loading": "Diving…", "empty": "Still water", "noSessions": "No dives underway", "searching": "Sounding for the Mac…", "composerReply": "Send a message in a bottle…", "composerListening": "Sonar on…"],
        loadingIcon: "sf:water.waves", loadingMotion: "bounce")

    public static let builtins: [RowTheme] = [
        off, rpg, movie, hades, mgs, agent, swe, scifi, west, cyber,
        gothic, musical, earth, cosmo, ocean,
    ]

    // MARK: custom themes

    /// `~/Library/Application Support/Infinitus/themes.json` — moved from
    /// the legacy `CswapBar/` dir as part of the one intentional
    /// bundle-id step (2026-08-30). A JSON array of RowTheme objects;
    /// only `id` and `name` are required.
    public static func customThemesURL(
        appSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        appSupport.appendingPathComponent("Infinitus/themes.json")
    }

    /// Best-effort load; a broken file yields [] rather than a crash —
    /// the popup must render with whatever themes are valid. Adopts the
    /// legacy CswapBar/themes.json once, by copy (the old file stays put
    /// so a rollback still finds it).
    public static func loadCustom(from url: URL = customThemesURL()) -> [RowTheme] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let legacy = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CswapBar/themes.json")
            if fm.fileExists(atPath: legacy.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.copyItem(at: legacy, to: url)
            }
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RowTheme].self, from: data)) ?? []
    }

    /// Persist the custom-theme list (community installs write through
    /// this); creates the directory on first use.
    public static func saveCustom(_ themes: [RowTheme],
                                  to url: URL = customThemesURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(themes).write(to: url)
    }

    /// A starter file for "Open themes file" when none exists yet —
    /// every themeable field shown so custom skins see the whole
    /// vocabulary (reconciled with the current struct, 2026-08-30).
    public static let templateJSON = """
    [
      {
        "id": "synthwave",
        "name": "Synthwave — neon grid",
        "sessionLabel": "SUN", "sessionColor": "#ff2d95",
        "weeklyLabel": "GRID", "weeklyColor": "#00e5ff",
        "scopedPrefix": "◆ ", "scopedColor": "#c77dff",
        "creditLabel": "CR", "creditColor": "#39ff14",
        "cashIcon": "🕶", "aheadIcon": "⚡",
        "deadMarker": "✖", "revivePrefix": "↻ ",
        "deadVerb": "offline", "readyLabel": "ONLINE",
        "flashColor": "#ff2d95",
        "modelAlias": {"Fable": "MAINFRAME", "Opus": "SERVER",
                       "Sonnet": "TERMINAL", "Haiku": "CHIP"},
        "planPrefix": "MHz ", "slotPrefix": "▸",
        "resetWord": "rebooting the grid…", "nextIcon": "⏭",
        "activeIcon": "🎧",
        "sessionWords": {"busy": "Rendering", "waiting": "Awaiting input",
                         "idle": "On standby", "shell": "In the console"},
        "tabLabels": {"sessions": "Tracks", "fleet": "Grid", "settings": "Console"},
        "tabIcons": {"sessions": "sf:waveform", "fleet": "sf:square.grid.3x3", "settings": "sf:slider.horizontal.3"},
        "loadingWords": {"loading": "Booting the grid…", "empty": "Empty track",
                         "noSessions": "No tracks playing", "searching": "Scanning for the Mac…"},
        "loadingIcon": "sf:waveform", "loadingMotion": "pulse"
      }
    ]
    """
}
