import SwiftUI

/// Quality rating control (W19.q4 — front-matter `quality` 0...3, 3 = highest). Purely
/// presentational: it renders the current rating and calls `onSet`, so the metadata inspector owns
/// the write (→ `NotesNavigationModel.setQuality` → `NotesModel`, which mirrors valid Q1...Q3 only
/// onto this note's own `.md`). Modeled on Reader's `TagEditorView.prioritySection` facet row.
///
/// A facet-button row **None · 1 · 2 · 3** with the current value highlighted — the explicit
/// "group / inspector" control from 06-viewers §8. (A compact inline menu variant + a context-menu
/// "Set Quality ▸" are a small follow-up, tracked in the Session Log, once the read-only list column
/// and item context menu grow their own edit affordances.)
struct QualityFacetRow: View {
    let quality: Int?
    let onSet: (Int?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            facetButton("None", current: quality == nil) { onSet(nil) }
            ForEach(1...3, id: \.self) { q in
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
