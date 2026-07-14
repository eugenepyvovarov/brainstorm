import Foundation
import Observation

/// App-wide recent + frequent emoji tracking (UserDefaults).
/// Shortlist is never a hardcoded palette — only what the user actually picks.
@Observable
@MainActor
public final class EmojiUsageStore {
    public static let shared = EmojiUsageStore()

    public static let maxRecent = 24
    public static let shortlistLimit = 16

    private let defaults: UserDefaults
    private let recentKey = "Brainstorm.emoji.recent"
    private let countsKey = "Brainstorm.emoji.counts"

    /// MRU order (index 0 = most recent).
    public private(set) var recent: [String]
    /// emoji → pick count
    public private(set) var counts: [String: Int]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.recent = Self.loadRecent(from: defaults, key: "Brainstorm.emoji.recent")
        self.counts = Self.loadCounts(from: defaults, key: "Brainstorm.emoji.counts")
    }

    /// Convenience for isolated tests (in-memory suite).
    public convenience init(suiteName: String) {
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        self.init(defaults: suite)
    }

    /// Record a successful emoji assignment (not clears).
    public func record(_ raw: String) {
        let emoji = Self.normalize(raw)
        guard !emoji.isEmpty else { return }

        var nextRecent = recent.filter { $0 != emoji }
        nextRecent.insert(emoji, at: 0)
        if nextRecent.count > Self.maxRecent {
            nextRecent = Array(nextRecent.prefix(Self.maxRecent))
        }
        recent = nextRecent

        var nextCounts = counts
        nextCounts[emoji, default: 0] += 1
        counts = nextCounts

        defaults.set(recent, forKey: recentKey)
        defaults.set(counts, forKey: countsKey)
    }

    /// Short row for the inspector: recents first, then most-used, then document-used.
    public func shortlist(documentEmojis: [String] = [], limit: Int = EmojiUsageStore.shortlistLimit) -> [String] {
        var result: [String] = []
        var seen = Set<String>()

        func append(_ items: [String]) {
            for raw in items {
                let e = Self.normalize(raw)
                guard !e.isEmpty, !seen.contains(e) else { continue }
                seen.insert(e)
                result.append(e)
                if result.count >= limit { return }
            }
        }

        append(recent)

        let frequent = counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map(\.key)
        append(frequent)
        append(documentEmojis)

        return result
    }

    public func clearHistory() {
        recent = []
        counts = [:]
        defaults.removeObject(forKey: recentKey)
        defaults.removeObject(forKey: countsKey)
    }

    /// First emoji-like grapheme cluster, else the first character of a short string.
    public static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        for ch in trimmed {
            let s = String(ch)
            if looksLikeEmoji(s) { return s }
        }
        // Allow single-character symbols (e.g. from Character Viewer)
        if let first = trimmed.first {
            return String(first)
        }
        return ""
    }

    public static func looksLikeEmoji(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }
        return string.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || (scalar.properties.isEmoji && scalar.value > 0xFF)
                || scalar.value == 0x200D
                || scalar.value == 0xFE0F
        }
    }

    private static func loadRecent(from defaults: UserDefaults, key: String) -> [String] {
        (defaults.array(forKey: key) as? [String])?
            .map(normalize)
            .filter { !$0.isEmpty } ?? []
    }

    private static func loadCounts(from defaults: UserDefaults, key: String) -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: key) as? [String: Int] else { return [:] }
        var out: [String: Int] = [:]
        for (k, v) in raw {
            let n = normalize(k)
            if !n.isEmpty, v > 0 { out[n] = v }
        }
        return out
    }
}
