import Foundation
import InfinitusCore

/// The phone's side of Core's `T3Terminal` wire (#507, spec F): the five
/// routes over the mirror client, and the attach stream — a never-ending
/// chunked NDJSON GET resumed with `since=<byte offset>`.
enum T3TerminalWire {
    private struct Kind: Decodable { let type: String }

    /// One NDJSON line as a Core frame; `nil` for a frame type this build
    /// does not know (skipped, never fatal — upstream adds `activity`,
    /// `restarted`, `cleared`); a malformed known frame still throws.
    static func decodeLine(_ line: Data) throws -> T3Terminal.Frame? {
        do {
            return try JSONDecoder().decode(T3Terminal.Frame.self, from: line)
        } catch {
            if let kind = try? JSONDecoder().decode(Kind.self, from: line),
               !["snapshot", "output", "exited", "closed", "error"].contains(kind.type) {
                return nil
            }
            throw error
        }
    }
}

extension T3Terminal.Frame {
    /// The byte offset a reconnect resumes from (`since`).
    var resumeSequence: Int? {
        switch self {
        case .snapshot(let s): return s.sequence
        case .output(let o): return o.sequence
        default: return nil
        }
    }
}

extension NetworkFleetMirror {
    func openTerminal(pid: Int32, cols: Int, rows: Int) async throws -> T3Terminal.OpenReply {
        let body = try JSONEncoder().encode(T3Terminal.OpenRequest(cols: cols, rows: rows))
        let data = try await sendData(T3Terminal.terminalPath(pid: pid), method: "POST", body: body)
        return try JSONDecoder().decode(T3Terminal.OpenReply.self, from: data)
    }

    func writeTerminal(pid: Int32, id: String, data: String) async throws {
        let capped = String(decoding: Array(data.utf8.prefix(T3Terminal.maxWriteBytes)), as: UTF8.self)
        _ = try await sendData(T3Terminal.terminalWritePath(pid: pid, id: id), method: "POST",
                               body: try JSONEncoder().encode(T3Terminal.WriteRequest(data: capped)))
    }

    func resizeTerminal(pid: Int32, id: String, cols: Int, rows: Int) async throws {
        _ = try await sendData(T3Terminal.terminalResizePath(pid: pid, id: id), method: "POST",
                               body: try JSONEncoder().encode(T3Terminal.ResizeRequest(cols: cols, rows: rows)))
    }

    func closeTerminal(pid: Int32, id: String) async throws {
        _ = try await sendData(T3Terminal.terminalClosePath(pid: pid, id: id), method: "DELETE", body: nil)
    }

    /// The attach stream: frames as they arrive, ending when the Mac ends
    /// the response; a non-2xx (404: no such terminal) throws `.http`.
    func terminalStream(pid: Int32, id: String, since: Int?) -> AsyncThrowingStream<T3Terminal.Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let request = streamRequest(path: T3Terminal.terminalStreamPath(pid: pid, id: id, since: since))
                    else { throw MirrorTransportError.closed }
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else { throw MirrorTransportError.http(status) }
                    for try await line in bytes.lines where !line.isEmpty {
                        if let frame = try T3TerminalWire.decodeLine(Data(line.utf8)) { continuation.yield(frame) }
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
