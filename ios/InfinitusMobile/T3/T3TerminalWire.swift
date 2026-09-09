import Foundation
import InfinitusCore

/// The Terminal wire (#507, spec F) as the phone speaks it until Core's
/// `T3Terminal` frames land: upstream `terminal.ts`'s frame and field names
/// verbatim, one shell per session (`terminalId` "default"), the attach
/// stream a never-ending chunked NDJSON GET resumed with `since=<sequence>`.
enum T3TerminalWire {
    static let defaultId = "default"
    static let writeCap = 65_536

    static func terminalPath(pid: Int32) -> String { "/sessions/\(pid)/terminal" }
    static func streamPath(pid: Int32, id: String) -> String { "\(terminalPath(pid: pid))/\(id)/stream" }
    static func writePath(pid: Int32, id: String) -> String { "\(terminalPath(pid: pid))/\(id)/write" }
    static func resizePath(pid: Int32, id: String) -> String { "\(terminalPath(pid: pid))/\(id)/resize" }
    static func closePath(pid: Int32, id: String) -> String { "\(terminalPath(pid: pid))/\(id)" }

    struct Size: Codable, Equatable {
        let cols: Int
        let rows: Int
    }

    /// `POST …/terminal`'s 201.
    struct Opened: Codable, Equatable {
        let terminalId: String
        let status: String
        let cwd: String
        let pid: Int32?
    }

    /// `TerminalSessionSnapshot`: the scrollback the Mac holds (a 256 KB
    /// ring) and where the shell stands.
    struct Snapshot: Codable, Equatable {
        let terminalId: String
        let status: String
        let history: String
        let sequence: Int?
        let exitCode: Int?
        let exitSignal: Int?
    }

    enum Frame: Equatable {
        case snapshot(Snapshot)
        case output(data: String, sequence: Int?)
        case exited(exitCode: Int?, exitSignal: Int?)
        /// `reason` (#507 ruling 5) tells a backpressure drop — resume —
        /// from a real close.
        case closed(reason: String?)
        case error(message: String)
        /// A frame this build does not know; skipped, never fatal.
        case other(type: String)

        private struct Raw: Decodable {
            let type: String
            let sequence: Int?
            let data: String?
            let snapshot: Snapshot?
            let exitCode: Int?
            let exitSignal: Int?
            let reason: String?
            let message: String?
        }

        /// One NDJSON line.
        static func decode(_ line: Data) throws -> Frame {
            let raw = try JSONDecoder().decode(Raw.self, from: line)
            switch raw.type {
            case "snapshot":
                guard let snapshot = raw.snapshot else { throw DecodingError.valueNotFound(Snapshot.self, .init(codingPath: [], debugDescription: "snapshot frame without a snapshot")) }
                return .snapshot(snapshot)
            case "output": return .output(data: raw.data ?? "", sequence: raw.sequence)
            case "exited": return .exited(exitCode: raw.exitCode, exitSignal: raw.exitSignal)
            case "closed": return .closed(reason: raw.reason)
            case "error": return .error(message: raw.message ?? "the Mac reported an error")
            default: return .other(type: raw.type)
            }
        }

        /// The cursor a reconnect resumes from.
        var sequence: Int? {
            switch self {
            case .snapshot(let s): return s.sequence
            case .output(_, let sequence): return sequence
            default: return nil
            }
        }
    }
}

extension NetworkFleetMirror {
    func openTerminal(pid: Int32, cols: Int, rows: Int) async throws -> T3TerminalWire.Opened {
        let body = try JSONEncoder().encode(T3TerminalWire.Size(cols: cols, rows: rows))
        let data = try await sendData(T3TerminalWire.terminalPath(pid: pid), method: "POST", body: body)
        return try JSONDecoder().decode(T3TerminalWire.Opened.self, from: data)
    }

    func writeTerminal(pid: Int32, id: String, data: String) async throws {
        _ = try await sendData(T3TerminalWire.writePath(pid: pid, id: id), method: "POST",
                               body: try JSONEncoder().encode(["data": String(data.utf8.prefix(T3TerminalWire.writeCap)) ?? data]))
    }

    func resizeTerminal(pid: Int32, id: String, cols: Int, rows: Int) async throws {
        _ = try await sendData(T3TerminalWire.resizePath(pid: pid, id: id), method: "POST",
                               body: try JSONEncoder().encode(T3TerminalWire.Size(cols: cols, rows: rows)))
    }

    func closeTerminal(pid: Int32, id: String) async throws {
        _ = try await sendData(T3TerminalWire.closePath(pid: pid, id: id), method: "DELETE", body: nil)
    }

    /// The attach stream: frames as they arrive, ending when the Mac ends
    /// the response; a non-2xx (404: no such terminal) throws `.http`.
    func terminalStream(pid: Int32, id: String, since: Int?) -> AsyncThrowingStream<T3TerminalWire.Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var path = T3TerminalWire.streamPath(pid: pid, id: id)
                    if let since { path += "?since=\(since)" }
                    guard let request = streamRequest(path: path) else { throw MirrorTransportError.closed }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw MirrorTransportError.http(status) }
                    for try await line in bytes.lines where !line.isEmpty {
                        continuation.yield(try T3TerminalWire.Frame.decode(Data(line.utf8)))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
