import SwiftUI
import ArchiveCore

// Inline, single-file tag editors that live in the navigation-list cells. Editing MULTIPLE selected
// files at once uses the ⌘I group editor; these cells act on exactly one file. Every change routes
// through the audited `TagWriter` (via NavigationModel) — no raw file mutation here.

/// Read-state cell — a borderless menu to set Read / Unread / clear on this one file.
struct ReadStateCell: View {
    @ObservedObject var model: NavigationModel
    let file: ArchiveFile
    var body: some View {
        Button { model.toggleReadState(for: file) } label: {   // C8: single click toggles Read↔Unread
            Text(file.readState?.rawValue ?? "—")
                .foregroundStyle(file.readState == .unread ? Color.accentColor : .secondary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Read")   { model.setReadStateInline(.read, for: file) }
            Button("Unread") { model.setReadStateInline(.unread, for: file) }
            if file.readState != nil {
                Divider()
                Button("Clear read-state") { model.clearReadState(for: file) }
            }
        }
        .help("Click to toggle Read/Unread · right-click for options · ⌘I edits several at once")
    }
}
