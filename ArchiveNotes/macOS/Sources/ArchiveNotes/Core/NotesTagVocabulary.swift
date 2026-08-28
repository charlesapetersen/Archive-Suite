import Foundation
import ArchiveCore

/// The Finder-tag vocabulary that `NotesTagProjector` manages on each note's `.md` file.
///
/// Managed tokens = title-cased user subjects plus the canonical Quality facet (`Q1`...`Q3`).
/// Everything else on the file (tags added by the user in Finder, Spotlight, etc.) is
/// untouched — the projector only ever adds/removes tokens in this set.
enum NotesTagVocabulary {
    /// The only quality spellings this app writes. `Q0` means unrated and is represented by the
    /// absence of a quality token, never by a `Q0` Finder tag.
    static let qualityTokens: Set<String> = ["Q1", "Q2", "Q3"]

    /// The set of tokens this projector manages for a given item: title-cased subjects plus its
    /// canonical Quality token when the front-matter rating is 1...3.
    static func managedTokens(for item: Item) -> Set<String> {
        var tokens = Set(item.tags.map { titleCased($0) })
        if let quality = qualityToken(for: item.quality) {
            tokens.insert(quality)
        }
        return tokens
    }

    /// The narrow desired set for a Quality-only reconciliation. It owns the Q facet but does not
    /// opportunistically project ordinary subjects during a body/date save. A literal Q-looking
    /// subject remains present so it cannot be mistaken for a stale facet and removed; the intended
    /// front-matter Quality token is appended last by `NotesTagProjector`.
    static func qualityProjectionTokens(for item: Item) -> Set<String> {
        var tokens = Set(item.tags.map { titleCased($0) }).intersection(qualityTokens)
        if let quality = qualityToken(for: item.quality) {
            tokens.insert(quality)
        }
        return tokens
    }

    /// Maps the human 0...3 quality scale to its on-disk Finder representation. Invalid values
    /// deliberately project nothing rather than inventing a non-contract token.
    static func qualityToken(for quality: Int?) -> String? {
        guard let quality, (1...3).contains(quality) else { return nil }
        return "Q\(quality)"
    }

    /// Title-case a subject using the shared convention (GeneratedTags.capitalizeFirstLetters):
    /// capitalize only the first letter of each word, preserving the rest.
    static func titleCased(_ subject: String) -> String {
        GeneratedTags.capitalizeFirstLetters(subject)
    }
}
