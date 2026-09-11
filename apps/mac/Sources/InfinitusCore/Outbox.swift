import Foundation

/// #168: one queued request per session, kept on disk until the Mac takes
/// it. The phone delivers; the Mac dedups (`InputDedup`) — so an item is
/// marked in flight BEFORE the send, and a leftover in-flight item after
/// a crash is simply sent again with the same `requestId`.
public struct OutboxItem: Codable, Sendable, Equatable, Identifiable {
    public enum State: Codable, Sendable, Equatable {
        case queued
        case inFlight
        case refused(String)
        case ended
    }

    public let id: UUID
    public let macKey: String
    public var pid: Int32
    public let sessionId: String?
    public let sessionName: String
    public var request: SessionInput.Request
    public let createdAt: Date
    public var updatedAt: Date
    public var attempts: Int
    public var state: State
}

public final class Outbox: @unchecked Sendable {
    public enum Delivery: Sendable, Equatable {
        case delivered
        case transport
        case refused(String)
        case ended
    }

    public struct FlushResult: Sendable, Equatable {
        public let id: UUID
        public let delivery: Delivery
    }

    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    /// Same date strategy `ParkedCache` uses, so `createdAt`/`updatedAt`/
    /// `queuedAt` survive a round trip.
    private static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }
    private static func decoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private func url(macKey: String, pid: Int32) -> URL {
        root.appendingPathComponent("\(macKey)-\(pid).json")
    }

    /// Every item for one Mac, oldest first. `createdAt` breaks ties by
    /// caller-supplied time; a merge (`enqueue` on an existing session)
    /// doesn't change it, so two items enqueued under the same `now` fall
    /// back to the file's on-disk write time, which is always real.
    public func items(macKey: String) -> [OutboxItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { $0.hasPrefix("\(macKey)-") && $0.hasSuffix(".json") }
            .compactMap { name -> (OutboxItem, Date)? in
                let url = root.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: url),
                      let item = try? Self.decoder().decode(OutboxItem.self, from: data) else { return nil }
                let writtenAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? item.createdAt
                return (item, writtenAt)
            }
            .sorted { $0.0.createdAt != $1.0.createdAt ? $0.0.createdAt < $1.0.createdAt : $0.1 < $1.1 }
            .map(\.0)
    }

    /// One per session: a second message for the same session joins the
    /// first as a new paragraph and gets a fresh `requestId` — the old one
    /// was never sent, or was sent and refused.
    @discardableResult
    public func enqueue(macKey: String, pid: Int32, sessionId: String?, sessionName: String,
                        request: SessionInput.Request, now: Date = Date()) throws -> OutboxItem {
        lock.lock(); defer { lock.unlock() }
        var item: OutboxItem
        if let existing = load(macKey: macKey, pid: pid) {
            item = existing
            let text = existing.request.text.isEmpty ? request.text
                : (request.text.isEmpty ? existing.request.text : existing.request.text + "\n\n" + request.text)
            let attachments = (existing.request.attachments ?? []) + (request.attachments ?? [])
            item.request = SessionInput.Request(kind: request.kind, text: text,
                                                attachments: attachments.isEmpty ? nil : attachments,
                                                requestId: UUID().uuidString, sessionId: sessionId ?? existing.sessionId)
            item.updatedAt = now
            item.state = .queued
        } else {
            // Keep the incoming id: a hand-typed send that timed out on
            // delivery may have already reached the Mac under this id, so
            // queuing it fresh must not mint a new one, or the retry is a
            // second, undeduped delivery (#168 fix pass).
            item = OutboxItem(id: UUID(), macKey: macKey, pid: pid, sessionId: sessionId,
                              sessionName: sessionName,
                              request: SessionInput.Request(kind: request.kind, text: request.text,
                                                            attachments: request.attachments,
                                                            requestId: request.requestId ?? UUID().uuidString,
                                                            sessionId: sessionId),
                              createdAt: now, updatedAt: now, attempts: 0, state: .queued)
        }
        try save(item)
        return item
    }

    /// The Edit path: the whole request is replaced, id regenerated.
    public func replace(id: UUID, request: SessionInput.Request, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard var item = all().first(where: { $0.id == id }) else { return }
        item.request = SessionInput.Request(kind: request.kind, text: request.text, attachments: request.attachments,
                                            requestId: UUID().uuidString, sessionId: item.sessionId)
        item.updatedAt = now
        item.state = .queued
        try save(item)
    }

    public func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let item = all().first(where: { $0.id == id }) else { return }
        try? FileManager.default.removeItem(at: url(macKey: item.macKey, pid: item.pid))
    }

    /// Persists an item as-is (tests use it to plant an in-flight item).
    public func save(_ item: OutboxItem) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.encoder().encode(item).write(to: url(macKey: item.macKey, pid: item.pid), options: .atomic)
    }

    /// Sends every queued (or stuck in-flight) item in order. A transport
    /// failure ends the pass — the Mac is gone again; a refusal or an
    /// ended session parks the item for the user and moves on.
    public func flush(macKey: String, now: Date = Date(),
                      deliver: (OutboxItem) async -> Delivery) async -> [FlushResult] {
        var results: [FlushResult] = []
        for candidate in items(macKey: macKey) {
            lock.lock()
            // Reload fresh under the lock rather than trusting the
            // `items()` snapshot above — a concurrent enqueue/replace/
            // remove between that snapshot and here must not be
            // overwritten by marking a stale copy in flight.
            guard var item = load(macKey: candidate.macKey, pid: candidate.pid) else { lock.unlock(); continue }
            switch item.state {
            case .refused, .ended: lock.unlock(); continue
            case .queued, .inFlight: break
            }
            item.state = .inFlight
            item.request = SessionInput.Request(kind: item.request.kind, text: item.request.text,
                                                attachments: item.request.attachments,
                                                requestId: item.request.requestId ?? UUID().uuidString,
                                                queuedAt: item.updatedAt, sessionId: item.sessionId)
            do { try save(item) } catch { lock.unlock(); continue }
            lock.unlock()

            let delivery = await deliver(item)
            results.append(FlushResult(id: item.id, delivery: delivery))

            lock.lock()
            if let onDisk = load(macKey: item.macKey, pid: item.pid) {
                if onDisk.request.requestId != item.request.requestId {
                    // A concurrent `enqueue` merged a new message into
                    // this same (macKey, pid) file while `deliver` was in
                    // flight — it carries a fresh `requestId`. Apply the
                    // outcome to that merged item instead of clobbering
                    // it with the stale one.
                    var merged = onDisk
                    switch delivery {
                    case .delivered:
                        // Keep only the part that wasn't sent: strip the
                        // delivered text/attachments as a prefix and
                        // queue the remainder under a fresh id for the
                        // next pass.
                        let sentText = item.request.text
                        let strippedText: String
                        if merged.request.text.hasPrefix(sentText + "\n\n") {
                            strippedText = String(merged.request.text.dropFirst((sentText + "\n\n").count))
                        } else if merged.request.text == sentText {
                            strippedText = ""
                        } else {
                            strippedText = merged.request.text
                        }
                        let sentAttachmentCount = item.request.attachments?.count ?? 0
                        let remainingAttachments = Array((merged.request.attachments ?? []).dropFirst(sentAttachmentCount))
                        merged.request = SessionInput.Request(kind: merged.request.kind, text: strippedText,
                                                              attachments: remainingAttachments.isEmpty ? nil : remainingAttachments,
                                                              requestId: UUID().uuidString, sessionId: merged.sessionId)
                        merged.state = .queued
                        try? save(merged)
                    case .transport:
                        merged.state = .queued
                        merged.attempts += 1
                        try? save(merged)
                    case .refused(let why):
                        merged.state = .refused(why)
                        try? save(merged)
                    case .ended:
                        merged.state = .ended
                        try? save(merged)
                    }
                } else {
                    switch delivery {
                    case .delivered:
                        try? FileManager.default.removeItem(at: url(macKey: item.macKey, pid: item.pid))
                    case .transport:
                        item.state = .queued
                        item.attempts += 1
                        try? save(item)
                    case .refused(let why):
                        item.state = .refused(why)
                        try? save(item)
                    case .ended:
                        item.state = .ended
                        try? save(item)
                    }
                }
            }
            // else: discarded mid-flight (`remove(id:)`) — never
            // resurrect it. The `FlushResult` above already recorded
            // the outcome.
            lock.unlock()

            if case .transport = delivery { return results }
        }
        return results
    }

    private func all() -> [OutboxItem] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            (try? Data(contentsOf: root.appendingPathComponent(name))).flatMap { try? Self.decoder().decode(OutboxItem.self, from: $0) }
        }
    }

    private func load(macKey: String, pid: Int32) -> OutboxItem? {
        guard let data = try? Data(contentsOf: url(macKey: macKey, pid: pid)) else { return nil }
        return try? Self.decoder().decode(OutboxItem.self, from: data)
    }
}
