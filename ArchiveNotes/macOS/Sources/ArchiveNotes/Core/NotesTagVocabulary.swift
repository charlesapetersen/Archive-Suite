import Foundation
import ArchiveCore

/// The Finder-tag vocabulary that `NotesTagProjector` manages on each note's `.md` file.
///
/// Managed tokens = title-cased user subjects + the `ArchiveSuite` membership marker.
/// Everything else on the file (tags added by the user in Finder, Spotlight, etc.) is
/// untouched — the projector only ever adds/removes tokens in this set.
enum NotesTagVocabulary {
    /// The suite membership marker (from ArchiveCore).
    static let suiteMarker = ArchiveSuiteMarker.tagName

    /// The set of tokens this projector manages for a given item:
    /// `titleCased(item.tags) ∪ {suiteMarker}`.
    static func managedTokens(for item: Item) -> Set<String> {
        var tokens = Set(item.tags.map { titleCased($0) })
        tokens.insert(suiteMarker)
        return tokens
    }

    /// Title-case a subject using the shared convention (GeneratedTags.capitalizeFirstLetters):
    /// capitalize only the first letter of each word, preserving the rest.
    static func titleCased(_ subject: String) -> String {
        GeneratedTags.capitalizeFirstLetters(subject)
    }
}
