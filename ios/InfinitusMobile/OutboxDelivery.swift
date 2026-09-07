import Foundation
import InfinitusCore
import UIKit
import UserNotifications

/// #168: the phone side of the outbox — where it lives on disk, how an
/// item is sent, and the notification when one lands while the app is
/// not on screen (the Mac pushes its own when the app is closed).
/// #144 phase 2: one queue per Mac, keyed by that Mac's token hash, each
/// flushed through its own mirror on its own reachable edge.
enum OutboxDelivery {
    static let outbox: Outbox = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return Outbox(root: support.appendingPathComponent("outbox"))
    }()

    /// The primary Mac's key.
    static var macKey: String { NetworkFleetMirror.parkedKey() }

    /// The key a session's queue files under: the primary's, or the
    /// hash of its own Mac's token.
    @MainActor static func macKey(for macId: String?, model: MirrorModel) -> String {
        guard let macId, let pairing = model.other(macId)?.pairing else { return macKey }
        return NetworkFleetMirror.parkedKey(token: pairing.token)
    }

    /// `reachableAgain` and the first-successful-load trigger can fire
    /// within moments of each other — single-flight PER KEY so a second
    /// call doesn't re-send an item the first call already marked in
    /// flight, while two Macs' flushes may run side by side.
    @MainActor private static var flushing: Set<String> = []

    static func flush() async { await flush(macId: nil) }

    static func flush(macId: String?) async {
        let model = MirrorModel.shared
        let (key, mirror) = await MainActor.run { (macKey(for: macId, model: model), model.mirror(for: macId)) }
        let canRun = await MainActor.run { flushing.insert(key).inserted }
        guard canRun else { return }
        defer { Task { @MainActor in flushing.remove(key) } }

        // Names and text by id, captured before the flush — a delivered
        // item's file is gone by the time `results` comes back.
        let items = outbox.items(macKey: key)
        let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.sessionName) })
        let texts = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.request.text) })
        let results = await outbox.flush(macKey: key) { item in await deliver(item, through: mirror) }
        let delivered = results.filter { $0.delivery == .delivered }
        guard !delivered.isEmpty else { return }
        let active = await MainActor.run { UIApplication.shared.applicationState == .active }
        if !active {
            for result in delivered {
                let content = UNMutableNotificationContent()
                content.title = names[result.id].map { "Delivered to \($0)" } ?? "Delivered"
                content.body = texts[result.id].map { String($0.prefix(80)) } ?? "Your queued message reached the session."
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: "outbox-\(result.id.uuidString)", content: content, trigger: nil))
            }
        }
    }

    static func deliver(_ item: OutboxItem, through mirror: NetworkFleetMirror) async -> Outbox.Delivery {
        do {
            let reply = try await mirror.sessionInput(pid: item.pid, request: item.request)
            switch reply.outcome {
            case "delivered", "running", "captured": return .delivered
            case "rejected" where reply.detail == "session ended": return .ended
            default: return .refused(reply.detail.map { "\(reply.outcome) — \($0)" } ?? reply.outcome)
            }
        } catch MirrorTransportError.http(409) {
            // The first delivery is still running on the Mac (#223 receipts);
            // the next pass gets its reply replayed.
            return .transport
        } catch MirrorTransportError.http(410) {
            // The user stopped the turn after this was sent: it stays stopped.
            return .refused("stopped before it landed")
        } catch MirrorTransportError.http(let code) {
            // The Mac answered — a rotated pairing token, most likely. Not
            // "gone", so the item must not retry forever as queued.
            return .refused("HTTP \(code)")
        } catch {
            return .transport
        }
    }
}
