import Foundation

/// The pure half of the terminal DRAWER — upstream's `mode: "drawer"`
/// (`apps/web/src/components/ThreadTerminalDrawer.tsx:989-1090` at 6c583620f):
/// the bottom drawer under the thread that shows the same shells the right
/// panel's Terminal tab does (#507 v4).
///
/// Three rules, all of them testable without a window:
///
/// - the HEIGHT: `MIN_DRAWER_HEIGHT` / `MAX_DRAWER_HEIGHT_RATIO` and
///   `clampDrawerHeight` (`:93-105`), over `DEFAULT_THREAD_TERMINAL_HEIGHT`
///   (`apps/web/src/types.ts:28`);
/// - the persisted per-thread SHAPE: `terminalOpen` + `terminalHeight`
///   (`apps/web/src/terminalUiStateStore.ts:20-27`, `:183-192`), the two
///   members of upstream's `ThreadTerminalUiState` that are the drawer's own
///   (the other four — the ids, the active one and the split groups — are the
///   live `T3TerminalGroup`'s here, keyed by (cwd, pid) rather than by thread,
///   because the shells are the Mac host's);
/// - which surface DRAWS the shells while both are open (`Presenters`).
public enum T3TerminalDrawer: Sendable {

    // MARK: - The height (`:93-105`)

    /// `MIN_DRAWER_HEIGHT` (`:93`).
    public static let minHeight: Double = 180
    /// `MAX_DRAWER_HEIGHT_RATIO` (`:94`).
    public static let maxHeightRatio: Double = 0.75
    /// `DEFAULT_THREAD_TERMINAL_HEIGHT` (`apps/web/src/types.ts:28`), which is
    /// also what a non-finite height falls back to (`:102`).
    public static let defaultHeight: Double = 280

    /// `maxDrawerHeight()` (`:96-99`): three quarters of the WINDOW, floored,
    /// never below the minimum. The viewport is the whole thread column's
    /// height, not the timeline's — upstream reads `window.innerHeight`, and
    /// measuring the box the drawer itself shrinks would feed its own height
    /// back into its cap.
    public static func maxHeight(viewport: Double) -> Double {
        guard viewport.isFinite, viewport > 0 else { return defaultHeight }
        return max(minHeight, (viewport * maxHeightRatio).rounded(.down))
    }

    /// `clampDrawerHeight` (`:101-105`): rounded, then held between the
    /// minimum and `maxDrawerHeight()`. A non-finite height is the default.
    public static func clamp(_ height: Double, viewport: Double) -> Double {
        let safe = height.isFinite ? height : defaultHeight
        return min(max(safe.rounded(), minHeight), maxHeight(viewport: viewport))
    }

    // MARK: - The persisted state (`terminalUiStateStore.ts:20-27`)

    /// One thread's drawer: open or not, and how tall it was left. The height
    /// is stored RAW and clamped where it is drawn — upstream's own split
    /// (`:1085` clamps the prop in the component; the store only turns a
    /// non-finite or non-positive number into the default,
    /// `terminalUiStateStore.ts:221-223`), so a drawer dragged tall on a big
    /// window is not shrunk forever by one session in a small one.
    public struct State: Codable, Equatable, Sendable {
        public var open: Bool
        public var height: Double

        public init(open: Bool = false, height: Double = T3TerminalDrawer.defaultHeight) {
            self.open = open
            self.height = T3TerminalDrawer.normalized(height)
        }

        /// `DEFAULT_THREAD_TERMINAL_UI_STATE` (`terminalUiStateStore.ts:183-192`)
        /// — the state a thread with no entry reads as.
        public static let none = State()

        /// A key written by another build may carry either member alone; a
        /// missing one reads as the default rather than dropping the entry.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            open = try container.decodeIfPresent(Bool.self, forKey: .open) ?? false
            height = T3TerminalDrawer.normalized(
                try container.decodeIfPresent(Double.self, forKey: .height) ?? T3TerminalDrawer.defaultHeight)
        }
    }

    /// `normalizeThreadTerminalUiState`'s height branch
    /// (`terminalUiStateStore.ts:221-223`): finite and positive, or the default.
    static func normalized(_ height: Double) -> Double {
        height.isFinite && height > 0 ? height : defaultHeight
    }

    /// `UserDefaults` data → one state per thread id. Unreadable or absent
    /// data is no state at all, never a crash (`T3ComposerDrafts.load`'s rule).
    public static func load(from data: Data?) -> [String: State] {
        guard let data, !data.isEmpty,
              let states = try? JSONDecoder().decode([String: State].self, from: data)
        else { return [:] }
        return states.filter { $0.value != .none }
    }

    /// States → `UserDefaults` data, the default ones dropped: upstream
    /// REMOVES a thread's entry the moment it reads as the default
    /// (`isDefaultThreadTerminalUiState`, `terminalUiStateStore.ts:508-514`),
    /// so a drawer closed at its default height leaves no key behind.
    public static func save(_ states: [String: State]) -> Data {
        (try? JSONEncoder().encode(states.filter { $0.value != .none })) ?? Data()
    }

    // MARK: - Who draws the shells (`ChatView.tsx:855-868`)

    /// The two places one session's terminals can be shown from.
    public enum Owner: String, Sendable, Equatable, CaseIterable {
        /// This drawer, under the thread.
        case drawer
        /// The right panel's Terminal tab (`mode="panel"`).
        case panel
    }

    /// Which owner is drawing, while both are mounted.
    ///
    /// Upstream never draws one terminal twice: a terminal claimed by a
    /// right-panel terminal surface leaves the drawer's list
    /// (`drawerTerminalSessions = knownTerminalSessions.filter(session =>
    /// !panelTerminalIds.has(session.target.terminalId))`, `ChatView.tsx:855-868`),
    /// so the drawer shows what the panel has not taken. That partition needs a
    /// "move this terminal to the panel" affordance, which this port has none
    /// of — its Terminal tab shows every terminal the session holds. And here
    /// it is not only a rule but a constraint: one `TerminalView` is one NSView
    /// and an NSView has one superview, so the same shell CANNOT be on screen
    /// in two places.
    ///
    /// So the partition is by SURFACE instead: the owner that appeared last
    /// draws the shells, the other says where they are. Nothing is detached
    /// while any owner is mounted — the shells outlive both.
    public struct Presenters: Sendable, Equatable {
        /// Mounted owners, oldest claim first.
        public private(set) var claims: [Owner] = []

        public init() {}

        /// The one drawing: the newest claim.
        public var current: Owner? { claims.last }
        /// Neither surface is mounted — the moment the entries detach.
        public var isEmpty: Bool { claims.isEmpty }

        /// An owner appeared. A re-claim MOVES it to the front of the queue:
        /// switching the right panel back to Terminal takes the shells back.
        public mutating func claim(_ owner: Owner) {
            claims.removeAll { $0 == owner }
            claims.append(owner)
        }

        /// An owner went away. The other one, if it is still mounted, takes
        /// the shells over — never a detach.
        public mutating func release(_ owner: Owner) {
            claims.removeAll { $0 == owner }
        }

        /// The line the owner that is NOT drawing shows in place of the
        /// emulators. There is no upstream string for it (upstream splits the
        /// terminals themselves instead), so it names the other surface the way
        /// the tab and the toggle do.
        public static func elsewhere(_ owner: Owner) -> String {
            switch owner {
            case .drawer: return "These shells are in the terminal drawer."
            case .panel: return "These shells are in the Terminal tab."
            }
        }
    }
}
