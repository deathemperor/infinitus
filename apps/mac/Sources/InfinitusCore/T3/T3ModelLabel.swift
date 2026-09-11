import Foundation

/// `activeThreadModelDisplayName` (`ChatComposer.tsx:5854`) is the model's
/// display name; the transcript carries only the id
/// (`claude-sonnet-4-5-20250929`), so this is ours: drop the vendor prefix
/// and the build date, keep the family and its version.
public enum T3ModelLabel {
    public static func display(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().joined(separator: ".")
        return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
    }
}
