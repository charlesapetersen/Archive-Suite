import Foundation

// MARK: - Shared per-item read model (Files ⇄ Live Capture)
//
// A1: one normalized view-model both the Process Files "Files" pane and the Live Capture "Processing"
// pane map INTO, so a single row/list component can render either without duplicating code. This file is
// UI-agnostic on purpose (Foundation only, no SwiftUI / no pipeline imports): the concrete domain types
// (`OCRJob`, `SegmentStatus`) are adapted into `ProcessableItem` by thin value types built where each pane
// already has the data — we do NOT make the domain models conform to a View protocol directly.

/// Normalized, richer-than-either item status. Note the `succeededNoText` case: the Files pane's binary
/// `text == nil` discriminator never needed it, but Live Capture does — a document that OCR'd to no text
/// but was still filed as a complete image-only PDF is a WARNING (amber), not a hard failure. It carries
/// no data-safety weight: it never changes when/what finalize deletes (that keys off `executePlans`'
/// `filedGroupIds`), only the label the operator sees.
///
/// `succeededPlaceholderImage` (W23.h5) is its mirror image: the text is fine but the IMAGE is missing —
/// the page's source photo couldn't be decoded, so the PDF carries the deliberate placeholder image page.
/// Also amber, also filed. Like the above it is a LABEL only: the matching data-safety decision (keep that
/// page's source photo instead of trashing it) is made from the segment's `placeholderSources`, not here.
enum ItemState: Equatable {
    case pending
    case processing(label: String)      // "OCR…", "Tagging…"
    case succeeded                      // filed, has OCR text
    case succeededNoText                // filed as an image-only PDF — WARN (amber), not error
    case succeededPlaceholderImage      // filed, but a page's PDF holds a placeholder, not the scan — WARN
    case failed(FailureKind)            // needs attention: nothing usable landed
    case removed                        // user-dropped page

    /// Whether this item is in a terminal-but-attention state the operator may want to act on.
    var needsAttention: Bool {
        switch self {
        case .failed, .succeededNoText, .succeededPlaceholderImage: return true
        default: return false
        }
    }
}

/// Why an item is `.failed`. Distinguishes the three causes Live Capture previously collapsed into a
/// single "Failed" so the row can label them honestly (none of these change any deletion decision).
enum FailureKind: Equatable {
    case noOutput           // produced no PDF at all
    case incompleteOutput   // some page produced no PDF → segment incomplete, finalize won't file it
    case ocrEmpty           // a document yielded no OCR text and no usable image-only PDF
    case provider           // a provider/transport error surfaced in the OCR result

    var label: String {
        switch self {
        case .noOutput: return "No output produced"
        case .incompleteOutput: return "Incomplete — a page produced no output"
        case .ocrEmpty: return "No OCR text"
        case .provider: return "Provider error"
        }
    }
}

/// Actions a pane can offer for an item. Not every action applies to every pane — each item advertises
/// the subset it supports via `availableActions`, and each pane supplies the handler.
enum ItemAction: Hashable {
    case retry                          // re-run with the original run/session backend
    case viewText                       // OCR text + error viewer
    case reclassify                     // Files only (box/folder/start/continuation)
    case changeRotation                 // rotate & re-run
    case revealFiles                    // Live only — reveal staged output in Finder
    case fileAsImageOnly                // force-file a no-text/failed doc as image-only

    var label: String {
        switch self {
        case .retry: return "Retry"
        case .viewText: return "View text"
        case .reclassify: return "Reclassify"
        case .changeRotation: return "Rotate & re-run"
        case .revealFiles: return "Reveal in Finder"
        case .fileAsImageOnly: return "File as image-only"
        }
    }

    var systemImage: String {
        switch self {
        case .retry: return "arrow.clockwise"
        case .viewText: return "doc.text.magnifyingglass"
        case .reclassify: return "tag"
        case .changeRotation: return "rotate.right"
        case .revealFiles: return "folder"
        case .fileAsImageOnly: return "photo"
        }
    }
}

/// The read model the shared row renders. Domain types map INTO this via adapters (`FileItem`,
/// `SegmentItem`) — see the note at the top of this file.
protocol ProcessableItem: Identifiable {
    var itemID: String { get }                 // job.id.uuidString / groupId
    var title: String { get }                  // filename / "3. Document · 4p"
    var subtitle: String? { get }              // classification displayName / page count
    var state: ItemState { get }
    var classification: DocumentClassification? { get }
    var rotationDegrees: Int? { get }
    var ocrText: String? { get }
    var errorMessage: String? { get }
    var errorCode: String? { get }
    var providerModel: String? { get }         // "Gemini · gemini-3.1-flash-lite"
    var availableActions: [ItemAction] { get }
    /// Finder tags applied to the output (Files pane). Defaulted empty so Live's `SegmentItem` can omit it.
    var appliedTags: [String] { get }
}

extension ProcessableItem {
    // `Identifiable` conformance from the stable per-item key.
    var id: String { itemID }
    var appliedTags: [String] { [] }
}

/// The row is action-source-agnostic: each pane supplies a handler that performs an action on an item id.
@MainActor protocol ProcessableItemActions {
    func perform(_ action: ItemAction, on itemID: String)
}
