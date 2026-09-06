import Foundation
import InfinitusCore
import UserNotifications

/// Schedules `FleetAlarms` as local notifications (#86): the reset alarms
/// are re-planned on every snapshot — pending requests replaced only when
/// the plan changes — and the swap banner posts at once. Off in Settings
/// clears the pending ones right away. When the Mac pushes its
/// alerts over APNs and this phone registered for them, the swap arrives
/// from the Mac instead, so the local one is skipped.
@MainActor
final class FleetAlarmCenter {
    static let shared = FleetAlarmCenter()
    static let enabledKey = "fleet_alarms"
    private var previousActive: Int??
    private var planned: [String: Date] = [:]

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    func sync(accounts: [Account], activeNumber: Int?, macPushesAlerts: Bool,
              lead: TimeInterval = FleetAlarms.lead, now: Date = Date()) {
        let center = UNUserNotificationCenter.current()
        defer { previousActive = .some(activeNumber) }
        if enabled, case .some(let previous) = previousActive,
           let swap = FleetAlarms.swap(from: previous, to: activeNumber, accounts: accounts),
           !(macPushesAlerts && LiveActivities.shared.alertTokenRegistered) {
            center.add(UNNotificationRequest(identifier: Self.prefix + swap.id,
                                             content: content(swap), trigger: nil))
        }
        let alarms = enabled ? FleetAlarms.resets(accounts: accounts, now: now, lead: lead) : []
        let plan = Dictionary(uniqueKeysWithValues: alarms.compactMap { a in a.fireAt.map { (a.id, $0) } })
        guard plan != planned else { return }
        let stale = planned.keys.filter { plan[$0] != planned[$0] }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale.map { Self.prefix + $0 })
        }
        for alarm in alarms where planned[alarm.id] != alarm.fireAt {
            guard let fireAt = alarm.fireAt else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fireAt.timeIntervalSince(now)), repeats: false)
            center.add(UNNotificationRequest(identifier: Self.prefix + alarm.id,
                                             content: content(alarm), trigger: trigger))
        }
        planned = plan
    }

    /// The toggle going off: nothing pending may fire before the next snapshot.
    func clearPending() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: planned.keys.map { Self.prefix + $0 })
        planned = [:]
    }

    private static let prefix = "fleet-alarm-"

    private func content(_ alarm: FleetAlarms.Alarm) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alarm.title
        content.body = alarm.body
        content.sound = .default
        return content
    }
}
