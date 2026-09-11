import Foundation
import MetricKit
import UIKit
import os
import InfinitusCore

/// The phone's own crashes and hangs, from MetricKit — delivered by iOS
/// on the launch after they happen — turned into `CrashReport`s and
/// posted to the Mac (`POST /crashes`). Nothing leaves the phone but for
/// that hop (user 2026-09-04: built-in crash tracking, no third party).
/// A report the Mac can't take right now waits in a spool for the next
/// launch.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()
    private let log = Logger(subsystem: "run.infinitus.mobile", category: "crash")
    private var spool: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("crash-spool")
    }

    func start() {
        MXMetricManager.shared.add(self)
        Task { await flush() }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                enqueue(report(kind: "crash", reason: Self.reason(crash), tree: crash.callStackTree,
                               meta: crash.metaData, at: payload.timeStampEnd))
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                enqueue(report(kind: "hang", reason: String(format: "main thread hung %.1f s", seconds),
                               tree: hang.callStackTree, meta: hang.metaData, at: payload.timeStampEnd))
            }
        }
        Task { await flush() }
    }

    private static func reason(_ crash: MXCrashDiagnostic) -> String {
        var parts: [String] = []
        if #available(iOS 17.0, *), let objc = crash.exceptionReason {
            parts.append("\(objc.exceptionName): \(objc.composedMessage)")
        }
        if let signal = crash.signal?.intValue {
            let names = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT", 8: "SIGFPE", 9: "SIGKILL",
                         10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE"]
            parts.append(names[signal] ?? "signal \(signal)")
        }
        if let type = crash.exceptionType?.intValue { parts.append("exception type \(type)") }
        if let why = crash.terminationReason, !why.isEmpty { parts.append(why) }
        return parts.isEmpty ? "crash" : parts.joined(separator: " · ")
    }

    private func report(kind: String, reason: String, tree: MXCallStackTree, meta: MXMetaData, at: Date) -> CrashReport {
        let json = tree.jsonRepresentation()
        return CrashReport(platform: "ios", device: UIDevice.current.name,
                           appVersion: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "?") (\(meta.applicationBuildVersion))",
                           osVersion: meta.osVersion, at: at, kind: kind, reason: reason,
                           frames: CrashReport.frames(fromCallStackTree: json),
                           raw: String(decoding: json.prefix(CrashReport.rawCap), as: UTF8.self))
    }

    private func enqueue(_ report: CrashReport) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
            try encoder.encode(report).write(to: spool.appendingPathComponent(report.id + ".json"), options: .atomic)
            log.notice("\(report.kind) spooled: \(report.reason)")
        } catch {
            log.error("couldn't spool a \(report.kind) report: \(error.localizedDescription)")
        }
    }

    /// Posts every spooled report; a delivered one leaves the spool.
    func flush() async {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: spool.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for name in names where name.hasSuffix(".json") {
            let url = spool.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let report = try? decoder.decode(CrashReport.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if await NetworkFleetMirror.shared.postCrash(report) {
                try? FileManager.default.removeItem(at: url)
                log.notice("\(report.kind) report delivered to the Mac")
            } else {
                log.notice("Mac unreachable; \(report.kind) report waits")
            }
        }
    }
}
