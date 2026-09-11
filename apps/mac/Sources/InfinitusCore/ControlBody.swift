import Foundation

/// `--body <json>` (#572, N1): the JSON a mirror route takes as its POST
/// body, carried on the control socket as a request option so the
/// fork's RPC — options are strings on both sides — passes it untouched;
/// `infinitusctl` fills it from stdin when the flag is absent. Decoded
/// the way the route decodes it: ISO-8601 dates, the same size cap.
/// Nothing in these bodies is a credential, which is why it may ride
/// argv; secrets keep to stdin → `secret`.
public enum ControlBody {
    public static let option = "body"

    /// `LocalizedError` so the socket's catch-all answers the message itself.
    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from request: ControlRequest,
                                            cap: Int? = nil) throws -> T {
        guard let text = request.options[option], !text.isEmpty else {
            throw Failure("\(request.command) needs --body <json> (or the JSON on stdin)")
        }
        let data = Data(text.utf8)
        if let cap, data.count > cap { throw Failure("\(request.command) body is over \(cap) bytes") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(type, from: data) }
        catch { throw Failure("\(request.command) body: \(describe(error))") }
    }

    static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return "\(error)" }
        switch decoding {
        case .keyNotFound(let key, _): return "missing \(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(context.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type"
        case .dataCorrupted(let context):
            return context.codingPath.isEmpty ? "not JSON" : "\(context.codingPath.map(\.stringValue).joined(separator: ".")) is malformed"
        @unknown default: return "\(decoding)"
        }
    }
}
