import BackgroundTasks
import Foundation
import os

/// Keeps the Live Activities honest while the app is in the background
/// (user 2026-09-03 "working sessions on LA doesn't seem to get
/// updated"): iOS grants a BGAppRefreshTask every so often (its call —
/// typically 15 min+ and only when the phone is idle/charged/on a
/// pattern); each one fetches a snapshot, which re-syncs both
/// activities. Genuinely live updates with the app closed need APNs
/// pushes from the Mac — the follow-up; this is the free tier.
enum BackgroundRefresh {
    static let taskID = "run.infinitus.mobile.refresh"
    private static let log = Logger(subsystem: "run.infinitus.mobile", category: "bg-refresh")

    static func register(model: MirrorModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()   // Always re-arm: the system hands out one at a time.
            let work = Task { @MainActor in
                await model.refresh()
                task.setTaskCompleted(success: model.snapshotLoaded)
                log.notice("background refresh done, loaded=\(model.snapshotLoaded)")
            }
            task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 10 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { log.error("couldn't schedule background refresh: \(error.localizedDescription)") }
    }
}
