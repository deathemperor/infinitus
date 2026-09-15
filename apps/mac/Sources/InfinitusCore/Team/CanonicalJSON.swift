import Foundation

/// The one JSON encoding signatures are computed over: sorted keys, no
/// escaped slashes, no floats in any signed document (timestamps are Int).
/// The same bytes come out of swift-foundation on Linux and Foundation on
/// Apple for that subset, which is what makes a signature made on one
/// platform verify on another.
public enum CanonicalJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
