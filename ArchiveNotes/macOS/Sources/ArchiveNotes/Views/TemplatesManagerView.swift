import SwiftUI

/// The per-window **templates manager** (06-viewers §6): shown in the item pane when the sidebar
/// "Templates" row (or a folder's "Template ▸ Manage…") is active. Lists every template (both kinds,
/// with a kind glyph) and offers New / Duplicate / Rename / Delete via `NotesModel`'s template actions.
///
/// Selecting a template opens its body in the detail editor. Selection is owned by the window so
/// the list and detail pane stay bound to the same template.
struct TemplatesManagerView: View {
    @ObservedObject var model: NotesModel
    @ObservedObject var nav: NotesNavigationModel

    @Binding var selected: UUID?
    @EnvironmentObject private var flushRegistry: EditorFlushRegistry
    @State private var showNew = false
    @State private var newName = ""
    @State private var newKind: Item.Kind = .note
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
                            .font(.caption).foregroundStyle(.primary)
                    }
                    .tag(t.id)
                    .accessibilityIdentifier("an.template.row.\(t.id.uuidString)")
                    .contextMenu { rowMenu(t) }
                }
            }
            .overlay { if model.templates.isEmpty { emptyState } }
            Divider()
            bottomBar
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onChange(of: model.templates.map(\.id)) { _, ids in
            if let selected, !ids.contains(selected) { self.selected = nil }
        }
        // The sheet asks which kind the template makes; it starts at this window's kind, in view, rather
        // than taking that kind silently (W40.fix-notes-new-note, notes-1 row 43).
        .sheet(isPresented: $showNew) {
            NameEntrySheet(title: "New Template", message: "A template starts each new note or extract made from it.",
                           confirmLabel: "Create", name: $newName,
                           onConfirm: { name in
                               let kind = newKind
                               Task { if let id = await model.createTemplate(name: name, kind: kind) { selected = id } }
                           },
                           accessory: AnyView(kindPicker))
        }
        .sheet(isPresented: boolBinding($renameID)) {
            let id = renameID
            NameEntrySheet(title: "Rename Template", confirmLabel: "Rename", name: $renameText) { name in
                guard let id else { return }
                Task { await model.renameTemplate(id, to: name) }
            }
        }
        .confirmationDialog("Delete this template?", isPresented: boolBinding($deleteID),
                            presenting: deleteID) { id in
            Button("Delete Template", role: .destructive) {
                Task {
                    await flushRegistry.flushAll()
                    guard !model.hasFailedTemplateBodySave(id) else { return }
                    await model.deleteTemplate(id)
                }
            }
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
                .accessibilityIdentifier("an.template.new")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    @ViewBuilder private func rowMenu(_ t: Template) -> some View {
        Button("Duplicate") {
            Task {
                await flushRegistry.flushAll()
                guard !model.hasFailedTemplateBodySave(t.id) else { return }
                if let id = await model.duplicateTemplate(t.id) { selected = id }
            }
        }
        Button("Rename…") { renameText = t.name; renameID = t.id }
        Divider()
        Button("Delete", role: .destructive) { deleteID = t.id }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Button { beginNew() } label: { Image(systemName: "plus") }.help("New Template")
            Button {
                if let id = selected {
                    Task {
                        await flushRegistry.flushAll()
                        guard !model.hasFailedTemplateBodySave(id) else { return }
                        if let copy = await model.duplicateTemplate(id) { selected = copy }
                    }
                }
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
            Text(selected == nil ? "Select a template to edit its body." : "Body edits save automatically.")
                .font(.callout).foregroundStyle(.primary)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.on.square").font(.title).foregroundStyle(.tertiary)
            Text("No templates yet").foregroundStyle(.primary)
            Text("Create one with +, then assign it to a folder via its “Template ▸” menu.")
                .font(.callout).foregroundStyle(.primary).multilineTextAlignment(.center)
        }
        .padding()
    }

    private func beginNew() { newName = "New Template"; newKind = nav.windowKind; showNew = true }

    private var kindPicker: some View {
        Picker("Makes", selection: $newKind) {
            Text("Notes").tag(Item.Kind.note)
            Text("Extracts").tag(Item.Kind.extract)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("an.template.new.kind")
    }

    private func boolBinding(_ id: Binding<UUID?>) -> Binding<Bool> {
        Binding(get: { id.wrappedValue != nil }, set: { if !$0 { id.wrappedValue = nil } })
    }
}
