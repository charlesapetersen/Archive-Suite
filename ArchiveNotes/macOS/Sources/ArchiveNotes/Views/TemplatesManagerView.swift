import SwiftUI

/// The per-window **templates manager** (06-viewers §6): shown in the item pane when the sidebar
/// "Templates" row (or a folder's "Template ▸ Manage…") is active. Lists every template (both kinds,
/// with a kind glyph) and offers New / Duplicate / Rename / Delete via `NotesModel`'s template actions.
///
/// Editing a template's *body* in the detail editor rides the same note-editor load/save path that is
/// itself not yet wired (deferred to Daemon Report with the note editor); the name + assignment +
/// new-from-template flows are complete now.
struct TemplatesManagerView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var nav: NotesNavigationModel

    @State private var selected: UUID?
    @State private var showNew = false
    @State private var newName = ""
    @State private var renameID: UUID?
    @State private var renameText = ""
    @State private var deleteID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: $selected) {
                ForEach(model.templates) { t in
                    HStack(spacing: 6) {
                        Image(systemName: t.kind == .extract ? "quote.opening" : "doc.text")
                            .foregroundStyle(.secondary)
                        Text(t.name.isEmpty ? "Untitled" : t.name).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(t.kind == .extract ? "Extract" : "Note")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .tag(t.id)
                    .contextMenu { rowMenu(t) }
                }
            }
            .overlay { if model.templates.isEmpty { emptyState } }
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier("an.templates.pane")
        .alert("New Template", isPresented: $showNew) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName
                Task { if let id = await model.createTemplate(name: name, kind: nav.windowKind) { selected = id } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a \(nav.windowKind == .extract ? "extract" : "note") template.")
        }
        .alert("Rename Template", isPresented: boolBinding($renameID), presenting: renameID) { id in
            TextField("Name", text: $renameText)
            Button("Rename") { Task { await model.renameTemplate(id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this template?", isPresented: boolBinding($deleteID),
                            presenting: deleteID) { id in
            Button("Delete Template", role: .destructive) { Task { await model.deleteTemplate(id) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Folders assigned to it fall back to their inherited or Blank template.")
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.on.square").foregroundStyle(.secondary)
            Text("Templates").font(.headline)
            Spacer()
            Button { beginNew() } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless).help("New Template")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private func rowMenu(_ t: Template) -> some View {
        Button("Duplicate") { Task { await model.duplicateTemplate(t.id) } }
        Button("Rename…") { renameText = t.name; renameID = t.id }
        Divider()
        Button("Delete", role: .destructive) { deleteID = t.id }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button { beginNew() } label: { Image(systemName: "plus") }.help("New Template")
            Button {
                if let id = selected { Task { await model.duplicateTemplate(id) } }
            } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate").disabled(selected == nil)
            Button {
                if let id = selected, let t = model.templates.first(where: { $0.id == id }) {
                    renameText = t.name; renameID = id
                }
            } label: { Image(systemName: "pencil") }.help("Rename").disabled(selected == nil)
            Button { if let id = selected { deleteID = id } } label: { Image(systemName: "trash") }
                .help("Delete").disabled(selected == nil)
            Spacer()
            Text("Editing a template's contents arrives with the note editor.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.on.square").font(.title).foregroundStyle(.tertiary)
            Text("No templates yet").foregroundStyle(.secondary)
            Text("Create one with +, then assign it to a folder via its “Template ▸” menu.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding()
    }

    private func beginNew() { newName = "New Template"; showNew = true }

    private func boolBinding(_ id: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { id.wrappedValue != nil }, set: { if !$0 { id.wrappedValue = nil } })
    }
}
