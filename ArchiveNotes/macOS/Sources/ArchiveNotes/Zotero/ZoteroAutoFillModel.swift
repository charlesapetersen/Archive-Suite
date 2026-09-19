import Foundation

/// One durable Zotero reference as it is represented on the selected note. Until B2 lands, the normal
/// UI attachment is a source block; keeping the two storage representations together makes B1 work on
/// that shipped path without guessing which of several citations a user meant.
struct ZoteroAutoFillReferenceTarget: Sendable, Equatable {
    let selectLink: String
    var noteFrontMatter: Bool
    var sourceBlocks: Bool
}

struct ZoteroAutoFillReference: Sendable, Equatable {
    let ref: ZoteroRef
    let target: ZoteroAutoFillReferenceTarget
}

enum ZoteroAutoFillReferenceResolution: Sendable, Equatable {
    case available(ZoteroAutoFillReference)
    case none
    case ambiguous
}

/// Resolves a source the user can safely auto-fill from. A note with exactly one distinct attached
/// reference is unambiguous; we never silently pick the first of several sources.
enum ZoteroAutoFillReferenceResolver {
    static func resolve(in item: Item) -> ZoteroAutoFillReferenceResolution {
        var candidates: [String: ZoteroAutoFillReference] = [:]

        for ref in item.zotero {
            var target = candidates[ref.selectLink]?.target
                ?? ZoteroAutoFillReferenceTarget(selectLink: ref.selectLink,
                                                  noteFrontMatter: false, sourceBlocks: false)
            target.noteFrontMatter = true
            candidates[ref.selectLink] = ZoteroAutoFillReference(ref: ref, target: target)
        }
        for block in item.blocks {
            guard let selectLink = block.source?.zoteroSelect,
                  let ref = ZoteroSelectLink.parse(selectLink) else { continue }
            if let candidate = candidates[selectLink] {
                let target = ZoteroAutoFillReferenceTarget(selectLink: candidate.target.selectLink,
                                                           noteFrontMatter: candidate.target.noteFrontMatter,
                                                           sourceBlocks: true)
                candidates[selectLink] = ZoteroAutoFillReference(ref: candidate.ref, target: target)
            } else {
                candidates[selectLink] = ZoteroAutoFillReference(
                    ref: ref,
                    target: ZoteroAutoFillReferenceTarget(selectLink: selectLink,
                                                          noteFrontMatter: false, sourceBlocks: true))
            }
        }

        switch candidates.count {
        case 0: return .none
        case 1: return .available(candidates.values.first!)
        default: return .ambiguous
        }
    }
}

/// View-model backing the "Auto-fill from Zotero" confirmation sheet
/// (00-overview §D.5). Because auto-fill overwrites `authors`/`date`/`title`,
/// the confirmation step is mandatory: the user reviews per-field changes,
/// toggles which to apply, and **only on confirm** is anything written.
///
/// Persistence is injected, so the view-model stays testable without a live
/// store and no test ever touches the real corpus — Prime Directive #1. The
/// app supplies `NotesModel`'s atomic transaction; cancelling writes nothing.
@MainActor
final class ZoteroAutoFillModel: ObservableObject, Identifiable {

    let id = UUID()

    /// Fields currently selected for application (init to the fill-empty default).
    @Published var selected: Set<AutoFillField>
    @Published private(set) var isSaving = false
    @Published private(set) var didCommit = false

    let plan: AutoFillPlan

    private let baseItem: Item
    /// The attached ref whose citation is refreshed on confirm (in front matter, source blocks, or both).
    private let refSelectLink: String
    private let referenceTarget: ZoteroAutoFillReferenceTarget
    private let citation: String?
    private let fetchedAt: Date
    // The model and its save action are both main-actor isolated. Keeping this closure actor-local lets
    // the app route confirmation through NotesModel's atomic transaction rather than falling back to a
    // stale whole-item overwrite.
    private let save: (Item) async throws -> Void

    init(item: Item,
         csl: ZoteroCSLItem,
         refSelectLink: String,
         citation: String? = nil,
         fetchedAt: Date = Date(),
         referenceTarget: ZoteroAutoFillReferenceTarget? = nil,
         save: @escaping (Item) async throws -> Void) {
        self.baseItem = item
        self.plan = AutoFillPlan.make(from: csl, item: item)
        self.refSelectLink = refSelectLink
        self.referenceTarget = referenceTarget
            ?? ZoteroAutoFillReferenceTarget(selectLink: refSelectLink,
                                              noteFrontMatter: true, sourceBlocks: false)
        self.citation = citation
        self.fetchedAt = fetchedAt
        self.save = save
        self.selected = plan.defaultSelection
    }

    /// The item that would be written given the current selection: selected
    /// front-matter fields applied, plus the matching attachment's fetched citation. A note-level ref
    /// also records `fetchedAt`; B1's existing source-block attachment displays the fetched citation.
    /// Pure — used for the sheet preview and by tests.
    var resolvedItem: Item {
        var out = plan.apply(selected: selected, to: baseItem)
        if referenceTarget.noteFrontMatter {
            out.zotero = out.zotero.map { ref in
                guard ref.selectLink == refSelectLink else { return ref }
                var stamped = ref
                if let citation, !citation.isEmpty { stamped.citation = citation }
                stamped.fetchedAt = fetchedAt
                return stamped
            }
        }
        if referenceTarget.sourceBlocks, let citation, !citation.isEmpty {
            out.blocks = out.blocks.map { block in
                guard block.source?.zoteroSelect == refSelectLink else { return block }
                var stamped = block
                stamped.source?.display = citation
                return stamped
            }
        }
        return out
    }

    func toggle(_ field: AutoFillField) {
        if selected.contains(field) { selected.remove(field) }
        else { selected.insert(field) }
    }

    func isSelected(_ field: AutoFillField) -> Bool { selected.contains(field) }

    /// Persist the resolved item via the injected store save, then mark committed.
    /// Rethrows a store failure so the sheet can surface it without claiming success.
    func confirm() async throws {
        isSaving = true
        defer { isSaving = false }
        try await save(resolvedItem)
        didCommit = true
    }

    /// Cancel writes nothing (00-overview §D.5).
    func cancel() { /* no-op by contract */ }
}
