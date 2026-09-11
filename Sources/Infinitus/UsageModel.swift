import SwiftUI
import Charts
import InfinitusCore
import InfinitusUI

/// Estimated spend dashboard (backlog item 4). The scan streams gigabytes
/// of transcripts (~seconds), so it runs on demand — first tab open and
/// the Refresh button — never on the snapshot timer.
@MainActor
final class UsageModel: ObservableObject {
    @Published var report: UsageReport?
    @Published var loading = false
    @Published var error: String?
    @Published var days = 7 { didSet { if days != oldValue { refresh() } } }

    private let cli: CswapCLI?
    /// True while `report` is last run's cached scan — the first
    /// loadIfNeeded still refreshes in the background.
    private var cacheOnly = false

    static let cacheURL: URL = {
        return AppSupport.root().appendingPathComponent("usage-cache.json")
    }()

    init(cli: CswapCLI?) {
        self.cli = cli
        // Same instant-render treatment as the account snapshot: the
        // cash column otherwise pops in seconds after launch (user
        // 2026-08-30: "cache doesn't seem to have cash data").
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode(UsageReport.self, from: data),
           cached.days == days {
            report = cached
            cacheOnly = true
        }
    }

    func loadIfNeeded() {
        if (report == nil || cacheOnly) && !loading { refresh() }
    }

    func refresh() {
        guard let cli, !loading else { return }
        loading = true
        error = nil
        let days = days
        Task {
            do {
                let (r, raw) = try await cli.usageReportRaw(days: days)
                if days == self.days {
                    try? FileManager.default.createDirectory(
                        at: Self.cacheURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    try? raw.write(to: Self.cacheURL, options: .atomic)
                }
                self.cacheOnly = false
                // Animated: the cash column's width change interpolates
                // (with the panel tracking it) instead of snapping the
                // popup wider in one frame (container-jump bug,
                // user 2026-08-30).
                withAnimation(.easeInOut(duration: 0.3)) { self.report = r }
            } catch {
                Lifecycle.log.error("usage scan failed: \(String(describing: error), privacy: .public)")
                self.error = "Couldn't scan the transcripts. Choose Refresh to try again."
            }
            self.loading = false
        }
    }
}

/// The cash column in the shared fleet views (#9 phase B) reads the
/// cached report through this.
extension UsageModel: UsageSource {}
