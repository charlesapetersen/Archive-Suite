import Foundation

/// View-model backing the "Auto-fill from Zotero" confirmation sheet
/// (00-overview §D.5). Because auto-fill overwrites `authors`/`date`/`title`,
/// the confirmation step is mandatory: the user reviews per-field changes,
/// toggles which to apply, and **only on confirm** is anything written.
///
/// Persistence goes through W2's atomic `NoteStore` save (injected as a
/// `@Sendable` closure so this view-model is testable without a live store and
/// so no test ever touches the real corpus — Prime Directive #1). Cancelling
/// writes nothing.
@MainActor
final class ZoteroAutoFillModel: ObservableObject {

    /// Fields currently selected for application (init to the fill-empty default).
    @Published var selected: Set<AutoFillField>
    @Published private(set) var isSaving = false
    @Published private(set) var didCommit = false

    let plan: AutoFillPlan

    private let baseItem: Item
    /// The attached ref whose `citation`/`fetchedAt` get stamped on confirm.
    private let refSelectLink: String
    private let citation: String?
    private let fetchedAt: Date
    private let save: @Sendable (Item) async throws -> Void

    init(item: Item,
         csl: ZoteroCSLItem,
         refSelectLink: String,
         citation: String? = nil,
         fetchedAt: Date = Date(),
         save: @escaping @Sendable (Item) async throws -> Void) {
        self.baseItem = item
        self.plan = AutoFillPlan.make(from: csl, item: item)
        self.refSelectLink = refSelectLink
        self.citation = citation
        self.fetchedAt = fetchedAt
        self.save = save
        self.selected = plan.defaultSelection
    }

    /// The item that would be written given the current selection: selected
    /// front-matter fields applied, plus the matching ref stamped with the
    /// fetched `citation` (the durable survivor, §5) and `fetchedAt`. Pure —
    /// used for the sheet preview and by tests.
    var resolvedItem: Item {
        var out = plan.apply(selected: selected, to: baseItem)
        out.zotero = out.zotero.map { ref in
            guard ref.selectLink == refSelectLink else { return ref }
            var stamped = ref
            if let citation, !citation.isEmpty { stamped.citation = citation }
            stamped.fetchedAt = fetchedAt
            return stamped
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
