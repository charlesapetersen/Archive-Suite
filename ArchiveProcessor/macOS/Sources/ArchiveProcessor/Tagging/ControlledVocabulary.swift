import Foundation

/// Post-parse enforcement for the optional subject-tag vocabulary. Prompt instructions are advisory;
/// this boundary guarantees only canonical configured spellings reach GeneratedTags.
enum ControlledVocabulary {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")

    private static func key(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: foldingLocale)
            .precomposedStringWithCanonicalMapping
    }

    static func enforce(_ proposed: [String], vocabulary: [String], limit: Int = 6) -> [String] {
        guard !vocabulary.isEmpty else { return Array(proposed.prefix(limit)) }

        var canonicalByKey: [String: String] = [:]
        for raw in vocabulary {
            let canonical = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { continue }
            let folded = key(canonical)
            canonicalByKey[folded] = canonicalByKey[folded] ?? canonical
        }

        var seen = Set<String>()
        var accepted: [String] = []
        for raw in proposed {
            let folded = key(raw)
            guard let canonical = canonicalByKey[folded], seen.insert(folded).inserted else { continue }
            accepted.append(canonical)
            if accepted.count == limit { break }
        }
        return accepted
    }
}
