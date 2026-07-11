// ArchiveSuiteMarker.swift — suite membership tag constant + recognition (ArchiveCore)

import Foundation

/// The Finder tag that Archive Notes projects onto its own `.md` files to mark them as
/// suite-managed. This is the **only** tag token the Notes projector adds beyond user subjects.
///
/// Recognition must handle the collision case: a user subject literally named `"ArchiveSuite"`
/// should not be misidentified as the membership marker in contexts where the distinction matters.
public enum ArchiveSuiteMarker {
    /// The exact Finder-tag string stamped onto suite-managed files.
    public static let tagName = "ArchiveSuite"

    /// Returns `true` if `tag` is the suite membership marker (case-sensitive exact match).
    public static func isMarker(_ tag: String) -> Bool {
        tag == tagName
    }

    /// Filters a list of tags, returning only those that are NOT the suite marker.
    /// Useful for extracting user-visible subjects from a tag list that includes the marker.
    public static func filterOutMarker(from tags: [String]) -> [String] {
        tags.filter { !isMarker($0) }
    }
}
