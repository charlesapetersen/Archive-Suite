import SwiftUI

/// Quality rating control (W6-S7 — 00-overview D9: front-matter `quality` 1…5, 5 = highest,
/// priority-style UI; NEVER a Finder tag). Purely presentational: it renders the current rating and
/// calls `onSet`, so the metadata inspector owns the write (→ `NotesNavigationModel.setQuality` →
/// `NotesModel`, front-matter only). Modeled on Reader's `TagEditorView.prioritySection` facet row.
///
/// A facet-button row **None · 1 · 2 · 3 · 4 · 5** with the current value highlighted — the explicit
/// "group / inspector" control from 06-viewers §8. (A compact inline menu variant + a context-menu
/// "Set Quality ▸" are a small follow-up, tracked in the Session Log, once the read-only list column
/// and item context menu grow their own edit affordances.)
struct QualityFacetRow: View {
    let quality: Int?
    let onSet: (Int?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            facetButton("None", current: quality == nil) { onSet(nil) }
            ForEach(1...5, id: \.self) { q in
                facetButton("\(q)", current: quality == q) { onSet(q) }
            }
        }
        .accessibilityIdentifier("an.detail.quality")
    }

    private func facetButton(_ label: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .buttonStyle(.bordered)
            .tint(current ? .accentColor : nil)
    }
}
