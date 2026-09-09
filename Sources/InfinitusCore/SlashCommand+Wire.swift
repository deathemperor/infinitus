import Foundation

/// `SlashCommand` on the mirror wire (`GET /sessions/<pid>/commands`):
/// the stored fields as-is; `id` and `insertion` are derived on both ends.
/// Spelled out because synthesis needs the declaring file, and that file's
/// API is left alone (B-5 adds its per-cwd cache there).
extension SlashCommand.Source: Codable {}
extension SlashCommand: Codable {
    private enum CodingKeys: String, CodingKey { case name, description, source }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(name: try c.decode(String.self, forKey: .name),
                  description: try c.decode(String.self, forKey: .description),
                  source: try c.decode(Source.self, forKey: .source))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        try c.encode(source, forKey: .source)
    }
}
