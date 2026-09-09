import Foundation
import InfinitusCore

/// The account badge on a Home row (upstream `2c8e95a4b`, `ProviderInstanceIcon`):
/// T3 shows an initials bubble on the provider glyph when several accounts
/// share a provider. Ours: a Mac with more than one account shows which one
/// the session runs on — the alias's initials (`providerInstanceInitials`,
/// `ProviderInstanceIcon.tsx:7`) or, unaliased, the account number.
enum T3AccountBadge {
    static func label(accountCount: Int, summary: SessionAccountSummary?) -> String? {
        guard accountCount > 1, let account = summary?.account else { return nil }
        if let alias = account.alias?.trimmingCharacters(in: .whitespaces), !alias.isEmpty {
            let text = initials(alias)
            if !text.isEmpty { return text }
        }
        return String(account.number)
    }

    /// One word: its first two letters; more: the first letter of the
    /// first two words. `_` and `-` split words like whitespace.
    static func initials(_ label: String) -> String {
        let words = label.replacingOccurrences(of: "[_-]+", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return "" }
        if words.count == 1 { return String(first.prefix(2)).uppercased() }
        return words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}
