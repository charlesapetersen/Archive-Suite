import SwiftUI
import ArchiveCore

struct NotesShellView: View {
    let kind: ItemKindShell
    @State private var sidebarWidth = 220.0
    @State private var detailWidth  = 360.0

    var body: some View {
        HStack(spacing: 0) {
            SidebarPane(kind: kind).frame(width: sidebarWidth)
            PanelDivider(width: $sidebarWidth, panelOnLeft: true, range: 160...360)
            ItemListPane(kind: kind).frame(maxWidth: .infinity, maxHeight: .infinity)
            PanelDivider(width: $detailWidth, panelOnLeft: false, range: 260...560)
            DetailPane(kind: kind).frame(width: detailWidth)
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

private struct SidebarPane: View {
    let kind: ItemKindShell
    var body: some View { placeholder("Folders") }
}

private struct ItemListPane: View {
    let kind: ItemKindShell
    var body: some View { placeholder("Items") }
}

private struct DetailPane: View {
    let kind: ItemKindShell
    var body: some View {
        NoteEditorPane()
    }
}

private func placeholder(_ t: String) -> some View {
    ZStack { Color(nsColor: .textBackgroundColor); Text(t).foregroundStyle(.tertiary) }
}
