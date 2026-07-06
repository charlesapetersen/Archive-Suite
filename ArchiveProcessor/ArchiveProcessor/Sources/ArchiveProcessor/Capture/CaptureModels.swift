import Foundation

/// The kind of thing a captured photo (and its group) represents. Mirrors the on-phone
/// grouping controls and the app's existing box/folder classification.
enum CaptureGroupType: String, Codable, CaseIterable {
    case document
    case box
    case folder

    /// macOS color tag applied to box/folder outputs (nil for ordinary documents).
    var colorTag: String? {
        switch self {
        case .box: return "Red"
        case .folder: return "Purple"
        case .document: return nil
        }
    }
}

/// One photo received from the phone during a live-capture session, already written to the
/// session's incoming folder.
struct CapturedPhoto: Identifiable, Equatable {
    let id = UUID()
    let url: URL              // local file in the session folder
    let groupId: String      // phone-assigned group identifier
    let seq: Int             // phone capture sequence (global order)
    let type: CaptureGroupType
    let receivedAt: Date
    /// Minimal on-phone tagging. Priority is per-photo ("P10"…"P7"; a page can override its
    /// group's default). Year/month are the group's date, repeated on each of its photos. Mutable:
    /// pages stream in as shot (before tagging), then `markSegmentComplete` attaches the segment's
    /// tags when the phone ends the segment.
    var priority: String?
    var year: Int?
    var month: Int?

    static func == (lhs: CapturedPhoto, rhs: CapturedPhoto) -> Bool { lhs.id == rhs.id }
}

/// A contiguous group of captured photos (a document / box / folder), as grouped on the phone.
struct CaptureGroup: Identifiable {
    let id: String           // groupId
    var type: CaptureGroupType
    var photos: [CapturedPhoto]
    /// Ordering key = the smallest seq among its photos (first-captured wins).
    var order: Int { photos.map { $0.seq }.min() ?? .max }
    /// Group date = first non-nil year/month among its photos (all should match).
    var year: Int? { photos.compactMap { $0.year }.first }
    var month: Int? { photos.compactMap { $0.month }.first }
    /// The group's priority default (first page's; per-page P10 overrides live on the photos).
    var priority: String? { photos.first?.priority }
}

/// Tags the Mac operator enters for a segment during Live Capture. Subjects are the piece the phone
/// doesn't capture; year/month/priority default to the phone's values but can be adjusted here.
struct MacSegmentTags: Equatable {
    var subjects: [String] = []
    var priority: String? = nil
    var year: Int? = nil
    var month: Int? = nil
}
