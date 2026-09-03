import Foundation
import ArchiveCore

/// The Finder-tag vocabulary that `NotesTagProjector` manages on each note's `.md` file.
///
/// Managed tokens = title-cased user subjects plus the canonical Quality and date facets.
/// Everything else on the file (tags added by the user in Finder, Spotlight, etc.) is
/// untouched — the projector only ever adds/removes tokens in this set.
enum NotesTagVocabulary {
    /// The only quality spellings this app writes. `Q0` means unrated and is represented by the
    /// absence of a quality token, never by a `Q0` Finder tag.
    static let qualityTokens: Set<String> = ["Q1", "Q2", "Q3"]

    /// The set of tokens this projector manages for a given item: title-cased subjects plus its
    /// canonical Quality and date tokens.
    static func managedTokens(for item: Item) -> Set<String> {
        var tokens = Set(item.tags.map { titleCased($0) })
        if let quality = qualityToken(for: item.quality) {
            tokens.insert(quality)
        }
        tokens.formUnion(dateFacetTokens(for: item))
        return tokens
    }

    /// Existing ArchiveCore date facets for the item's exact, normalized front-matter date. The array
    /// order is deliberate: the projector appends these after user subjects, so a subject such as
    /// `1984` cannot become the parsed date when the authoritative date is `1968`.
    static func dateFacetTokens(for item: Item) -> [String] {
        guard let date = item.date, let precision = item.datePrecision,
              Item.normalizedDate(date, precision: precision) == (date, precision) else { return [] }

        switch precision {
        case .decade:
            guard let decade = DocumentTags.parseDecade("\(date)s"),
                  DocumentTags.sortDateKey(year: nil, month: nil, day: nil, decade: decade) != nil else { return [] }
            return ["\(decade)s"]
        case .year:
            guard let year = DocumentTags.parseYear(date),
                  DocumentTags.sortDateKey(year: year, month: nil, day: nil, decade: nil) != nil else { return [] }
            return ["\(year)"]
        case .month:
            let parts = date.split(separator: "-")
            guard parts.count == 2, let year = DocumentTags.parseYear(String(parts[0])), let month = Int(parts[1]),
                  (1...12).contains(month),
                  DocumentTags.sortDateKey(year: year, month: month, day: nil, decade: nil) != nil else { return [] }
            return ["\(year)", String(format: "%02d %@", month, DocumentTags.monthNames[month - 1])]
        case .day:
            let parts = date.split(separator: "-")
            guard parts.count == 3, let year = DocumentTags.parseYear(String(parts[0])), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1...12).contains(month), GregorianDay.isValidDay(year: year, month: month, day: day),
                  DocumentTags.sortDateKey(year: year, month: month, day: day, decade: nil) != nil else { return [] }
            return ["\(year)", String(format: "%02d %@", month, DocumentTags.monthNames[month - 1]), "Day \(day)"]
        }
    }

    /// The intentionally narrow projection used by the date/Quality metadata path. Keep a current
    /// subject that looks like a date or Q token in `desired`, so a date change cannot remove it; the
    /// explicit facet tokens are ordered separately by `NotesTagProjector` and therefore still win
    /// ArchiveCore's last-token-wins parsing.
    static func facetProjectionTokens(for item: Item) -> Set<String> {
        var tokens = Set(item.tags.map { titleCased($0) }.filter {
            qualityTokens.contains($0) || DocumentTags.isDateFacetLike($0)
        })
        tokens.formUnion(dateFacetTokens(for: item))
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
