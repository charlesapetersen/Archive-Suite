import Foundation
import UserNotifications

// MARK: - Collection Review Item

/// Represents a single file's classification and collection assignment for user review.
struct CollectionReviewItem: Identifiable {
    let id = UUID()
    let fileIndex: Int
    let fileName: String
    let fileURL: URL
    var classification: DocumentClassification?
    var collectionName: String
    /// Whether this item was identified as a box label (and thus defines a collection boundary)
    var isBoxLabel: Bool
    /// Clockwise degrees to correct the image's orientation (from OCR / rotation review), for display.
    var rotationDegrees: Int = 0
}

// MARK: - Document Segment Review Item

/// Represents a single file's document_start/document_continuation classification for review.
struct DocumentReviewItem: Identifiable {
    let id = UUID()
    let fileIndex: Int
    let fileName: String
    let fileURL: URL
    var classification: DocumentClassification?
    var rotationDegrees: Int = 0
    /// User flagged this photo for removal during review (extraneous image).
    var markedForRemoval: Bool = false
}

// MARK: - Manual Tag Segment

/// One image shown in the manual tagging UI, with its corrected rotation. A context image
/// is the nearest preceding box/folder label — shown for orientation but NOT tagged.
struct ManualTagImage: Identifiable {
    let id = UUID()
    let url: URL
    let rotationDegrees: Int
    let isContext: Bool
}

// MARK: - Manual Segmentation + Tagging (fully human mode)

/// The kind of a photo in the manual segmentation UI. Box/folder photos are dividers that
/// receive only a color tag; documents are grouped into tagged segments.
enum ManualPhotoKind: Hashable { case document, box, folder
    var isBoxOrFolder: Bool { self != .document }
}

/// One image in the fully-manual segmentation UI. Rotation and kind are user-editable.
struct ManualSegImage: Identifiable {
    let id = UUID()
    let fileIndex: Int          // stable index into the run's `files`/`jobs` arrays — the key
    let url: URL
    var rotationDegrees: Int
    var kind: ManualPhotoKind
}

/// A document segment the user has identified and tagged. Its pages drop out of the viewer.
struct CompletedManualSegment: Identifiable {
    let id = UUID()
    let indices: [Int]          // ordered indices into `manualSegImages`; first is the segment start
    var tags: SegmentTagData
}

/// Date + subject tags the user enters for one manually-defined segment. (The trailing "Unread"
/// tag is added automatically by `MacOSTagger.applyTags` in stamping modes, so it is not seeded here.)
struct SegmentTagData {
    var year: String = ""
    var month: String = ""      // "MM Month"
    var day: String = ""        // "Day D"
    var dateUncertain: Bool = false
    var subjectTags: [String] = []
}

/// One document segment presented for manual/human tagging (feature 6).
struct ManualTagSegment: Identifiable {
    let id = UUID()
    /// Index into the processor's `segments` array.
    let segmentIndex: Int
    /// Images to display: an optional leading box/folder context image, then the segment pages.
    let images: [ManualTagImage]
    // Editable date fields
    var year: String = ""
    var month: String = ""      // "MM Month", e.g. "03 March"
    var day: String = ""        // "Day D", e.g. "Day 15"
    var dateUncertain: Bool = false
    var subjectTags: [String] = []
    /// True while the auto-date LLM prefetch for this segment is still in flight.
    var dateLoading: Bool = false
}
