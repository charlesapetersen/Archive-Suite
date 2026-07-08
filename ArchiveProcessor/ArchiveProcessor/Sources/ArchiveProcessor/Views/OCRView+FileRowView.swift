import SwiftUI
import UniformTypeIdentifiers
import PDFKit
import ImageIO

// MARK: - File Row (Process Files) — thin adapter over the shared ProcessableItemRow

/// Adapts the Files pane's `(url, job, presetClassification)` inputs into the shared `ProcessableItem`
/// read model and renders the shared row. Behavior/appearance are preserved: same status icons, same
/// classification capsule/tint, same rotation badge, same applied-tags layout, same red failure line.
struct FileRowView: View {
    let url: URL
    let job: OCRJob?
    var showTags: Bool = false
    var isFocused: Bool = false
    /// Per-item actions (populated for the Files disclosure); empty by default so the row stays compact.
    var actions: ProcessableItemActions = ItemActionHandler { _, _ in }
    var isExpanded: Bool = false
    /// Live Capture segmentation to show before a job exists (falls back to `job.classification`).
    var presetClassification: DocumentClassification? = nil
    @AppStorage(DefaultsKeys.taggingModeRaw) private var taggingModeRaw: String = TaggingMode.automatic.rawValue

    /// Document start/continuation only mean something when the LLM segments (Automatic / Auto-date).
    /// In manual-segmentation, Human, No-tagging, and Copy-source modes those are user-defined or
    /// unused, so they shouldn't clutter the file pane. Box/folder markers always show.
    private func shows(_ c: DocumentClassification) -> Bool {
        if c == .documentStart || c == .documentContinuation {
            return (TaggingMode(rawValue: taggingModeRaw) ?? .automatic).llmSegments
        }
        return true
    }

    var body: some View {
        ProcessableItemRow(item: fileItem, badgeStyle: .icon, isExpanded: isExpanded,
                           isFocused: isFocused, showTagsList: showTags, actions: actions)
    }

    /// Build the normalized read model from this row's inputs.
    private var fileItem: FileItem {
        let cls = job?.classification ?? presetClassification
        let shownClass = (cls != nil && shows(cls!)) ? cls : nil
        return FileItem(url: url, job: job, shownClassification: shownClass,
                        availableActions: isExpanded ? Self.filesActions(for: job) : [])
    }

    /// Actions a Files row offers. Retry/model/rotation only make sense for a failed OCR; every row can
    /// view text / reclassify during review.
    static func filesActions(for job: OCRJob?) -> [ItemAction] {
        var acts: [ItemAction] = []
        if job?.status == .failed {
            acts.append(contentsOf: [.retry, .retryWithModel, .changeRotation])
        }
        acts.append(contentsOf: [.viewText, .reclassify])
        return acts
    }
}

/// Files-pane adapter: maps an `OCRJob` (+ source URL / preset classification) into a `ProcessableItem`.
struct FileItem: ProcessableItem {
    let itemID: String
    let title: String
    let subtitle: String?
    let state: ItemState
    let classification: DocumentClassification?
    let rotationDegrees: Int?
    let ocrText: String?
    let errorMessage: String?
    let errorCode: String?
    let providerModel: String?
    let availableActions: [ItemAction]
    let appliedTags: [String]

    init(url: URL, job: OCRJob?, shownClassification: DocumentClassification?,
         availableActions: [ItemAction] = []) {
        self.itemID = job?.id.uuidString ?? url.path
        self.title = url.lastPathComponent
        self.subtitle = nil
        self.state = Self.state(for: job)
        self.classification = shownClassification
        self.rotationDegrees = (job?.result?.rotationDegrees).flatMap { $0 != 0 ? $0 : nil }
        self.ocrText = job?.result?.text
        self.errorMessage = job?.result?.errorMessage
        self.errorCode = job?.result?.errorCode
        self.providerModel = nil    // Files pane historically doesn't surface provider·model here
        self.availableActions = availableActions
        self.appliedTags = job?.appliedTags ?? []
    }

    private static func state(for job: OCRJob?) -> ItemState {
        guard let job else { return .pending }
        switch job.status {
        case .pending: return .pending
        case .processing: return .processing(label: "OCR…")
        case .succeeded: return .succeeded   // Files: succeeded ⟺ text != nil (see handleOCRResult)
        case .failed: return .failed(job.result?.errorMessage != nil ? .provider : .ocrEmpty)
        case .removed: return .removed
        }
    }
}

