import SwiftUI

/// Quality rating control (W19.q4 — front-matter `quality` 0...3, 3 = highest). Purely
/// presentational: it renders the current rating and calls `onSet`, so the metadata inspector owns
/// the write (→ `NotesNavigationModel.setQuality` → `NotesModel`, which mirrors valid Q1...Q3 only
/// onto this note's own `.md`). Modeled on Reader's `TagEditorView.prioritySection` facet row.
///
/// A facet-button row **None · 1 · 2 · 3** with the current value highlighted — the explicit
/// "group / inspector" control from 06-viewers §8.
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

/// Compact quality editor for a virtualized table row. The parent supplies the item's current
/// value every time the row is reused; selection alone never writes front matter.
struct QualityInlineMenu: View {
    let itemID: UUID
    let quality: Int?
    let onSet: (Int?) -> Void

    var body: some View {
        Menu {
            Button("None") { onSet(nil) }
            ForEach(1...3, id: \.self) { value in
                Button("Quality \(value)") { onSet(value) }
            }
        } label: {
            HStack(spacing: 3) {
                Text(quality.map { String(repeating: "★", count: $0) } ?? "—")
                    .foregroundStyle(quality == nil ? Color.secondary : Color.yellow)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .accessibilityLabel("Quality")
        .accessibilityValue(quality.map { "Quality \($0)" } ?? "None")
        .accessibilityIdentifier("an.cell.quality.\(itemID.uuidString)")
    }
}
