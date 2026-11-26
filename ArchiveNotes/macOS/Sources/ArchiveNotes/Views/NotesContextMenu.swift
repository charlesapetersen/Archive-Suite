import AppKit

/// Retains a closure so a plain `NSMenuItem` can fire it. `NSMenuItem.target` is a weak reference, so
/// the trampoline is also stashed in the item's `representedObject` (strong) to keep it alive for the
/// menu's lifetime.
@MainActor
final class NotesMenuAction: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// Builds the item-row context menu for the Notes table: item actions plus **Add to Folder ▸**
/// (replicate) and **Move to Folder ▸** over the normal-folder list, and a guarded folder removal when
/// the list is scoped to a normal folder.
enum NotesItemContextMenu {

    @MainActor
    static func make(nav: NotesNavigationModel, selection: Set<UUID>, flushing registry: EditorFlushRegistry,
                     archiveRoots: @escaping @MainActor () -> [URL] = { [] }) -> NSMenu? {
        guard !selection.isEmpty else { return nil }
        let ids = Array(selection)
        let model = nav.model
        let normals = model.organization.folders
            .filter { $0.kind == .normal }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let menu = NSMenu()

        if selection.count == 1, let id = selection.first {
            let summary = model.allItems.first { $0.id == id }
            let open = NSMenuItem(title: "Open", action: #selector(NotesMenuAction.fire), keyEquivalent: "")
            let openAction = NotesMenuAction { nav.select(id) }
            open.target = openAction
            open.representedObject = openAction
            menu.addItem(open)

            let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(NotesMenuAction.fire), keyEquivalent: "")
            let revealAction = NotesMenuAction { Task { await model.revealInFinder(id) } }
            reveal.target = revealAction
            reveal.representedObject = revealAction
            menu.addItem(reveal)

            let copyLink = NSMenuItem(title: "Copy Link", action: #selector(NotesMenuAction.fire), keyEquivalent: "")
            let action = NotesMenuAction { _ = model.copyOpenLink(for: id) }
            copyLink.target = action
            copyLink.representedObject = action
            menu.addItem(copyLink)

            if let summary {
                let offered = model.templates(matching: summary.kind)
                let templateMenu = NSMenu()
                func addNewFromTemplate(_ title: String, templateId: UUID?) {
                    let item = NSMenuItem(title: title, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
                    let trampoline = NotesMenuAction {
                        Task {
                            guard let newID = await NewItemFlow.create(kind: summary.kind, from: templateId,
                                                                       model: model, flushing: registry)
                            else { return }
                            nav.showingTemplates = false
                            nav.select(newID)
                        }
                    }
                    item.target = trampoline
                    item.representedObject = trampoline
                    templateMenu.addItem(item)
                }
                addNewFromTemplate("Blank", templateId: nil)
                if !offered.isEmpty { templateMenu.addItem(.separator()) }
                for template in offered {
                    addNewFromTemplate(template.name, templateId: template.id)
                }
                let fromTemplate = NSMenuItem(title: "New from Template", action: nil, keyEquivalent: "")
                fromTemplate.submenu = templateMenu
                menu.addItem(fromTemplate)
            }
        }

        // Set Quality and Delete… act on every selected row (W49.notes-multiselect-actions): a value is ticked
        // when every selected note has it, and several selected notes are deleted after one prompt.
        let summaries = model.allItems.filter { selection.contains($0.id) }
        let ordered = nav.displayed.lazy.filter { selection.contains($0.id) }.map(\.id)
        let orderedIDs = ordered.isEmpty ? ids : Array(ordered)
        if !summaries.isEmpty {
            let qualities = Set(summaries.map(\.quality))
            let qualityMenu = NSMenu()
            for (title, value) in [("None", Optional<Int>.none), ("Quality 1", 1),
                                   ("Quality 2", 2), ("Quality 3", 3)] {
                let item = NSMenuItem(title: title, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
                item.state = qualities == [value] ? .on : (qualities.contains(value) ? .mixed : .off)
                let trampoline = NotesMenuAction { Task { await nav.setQuality(value, for: orderedIDs) } }
                item.target = trampoline
                item.representedObject = trampoline
                qualityMenu.addItem(item)
            }
            let setQuality = NSMenuItem(title: "Set Quality", action: nil, keyEquivalent: "")
            setQuality.submenu = qualityMenu
            menu.addItem(setQuality)

            // Several notes: their tags, to take one off them all (the inspector adds one to them all).
            let tags = NoteBulkTags.tags(in: summaries)
            if selection.count > 1, !tags.isEmpty {
                let removeMenu = NSMenu()
                for entry in tags {
                    let title = entry.count == summaries.count ? entry.tag : "\(entry.tag) (\(entry.count))"
                    let item = NSMenuItem(title: title, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
                    let trampoline = NotesMenuAction { Task { await nav.removeTag(entry.tag, from: orderedIDs) } }
                    item.target = trampoline
                    item.representedObject = trampoline
                    removeMenu.addItem(item)
                }
                let removeTag = NSMenuItem(title: "Remove Tag", action: nil, keyEquivalent: "")
                removeTag.submenu = removeMenu
                menu.addItem(removeTag)
            }
            menu.addItem(.separator())
        }

        // Shows ⌘⌫, Edit ▸ Delete Note…'s key (W40.fix-notes-delete-redo).
        let delete = NSMenuItem(title: selection.count > 1 ? "Delete \(selection.count) Notes…" : "Delete…",
                                action: #selector(NotesMenuAction.fire), keyEquivalent: "\u{8}")
        delete.keyEquivalentModifierMask = .command
        let deleteAction = NotesMenuAction { nav.requestDeleteItems(orderedIDs) }
        delete.target = deleteAction
        delete.representedObject = deleteAction
        menu.addItem(delete)
        menu.addItem(.separator())

        // Export… and Print… of the clicked rows, in list order (W49.notes-export-print; File ▸ Export… and ⌘P).
        let exportIDs = orderedIDs
        let exportItem = NSMenuItem(title: selection.count > 1 ? "Export \(selection.count) Items…" : "Export…",
                                action: #selector(NotesMenuAction.fire), keyEquivalent: "")
        let exportAction = NotesMenuAction {
            Task { await NoteExportFlow.export(exportIDs, model: model, registry: registry, archiveRoots: archiveRoots()) }
        }
        exportItem.target = exportAction
        exportItem.representedObject = exportAction
        menu.addItem(exportItem)
        let printItem = NSMenuItem(title: "Print…", action: #selector(NotesMenuAction.fire), keyEquivalent: "")
        let printAction = NotesMenuAction {
            Task { await NoteExportFlow.print(exportIDs, model: model, registry: registry) }
        }
        printItem.target = printAction
        printItem.representedObject = printAction
        menu.addItem(printItem)
        menu.addItem(.separator())

        func folderSubmenu(_ action: @escaping (UUID) -> Void) -> NSMenu {
            let sub = NSMenu()
            if normals.isEmpty {
                let none = NSMenuItem(title: "No folders yet", action: nil, keyEquivalent: "")
                none.isEnabled = false
                sub.addItem(none)
            }
            for f in normals {
                let item = NSMenuItem(title: f.name, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
                let trampoline = NotesMenuAction { action(f.id) }
                item.target = trampoline
                item.representedObject = trampoline   // keep the trampoline alive (target is weak)
                sub.addItem(item)
            }
            return sub
        }

        let add = NSMenuItem(title: "Add to Folder", action: nil, keyEquivalent: "")
        add.submenu = folderSubmenu { target in Task { await nav.replicate(ids, to: target) } }
        menu.addItem(add)

        let source = model.selectedFolderId
        let move = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
        move.submenu = folderSubmenu { target in Task { await nav.move(ids, to: target, from: source) } }
        menu.addItem(move)

        // "Remove from this folder" only when the list is scoped to a specific normal folder.
        if let source, let folder = model.organization.folders.first(where: { $0.id == source }) {
            menu.addItem(.separator())
            let title = selection.count > 1
                ? "Remove \(selection.count) Items from “\(folder.name)”"
                : "Remove from “\(folder.name)”"
            let remove = NSMenuItem(title: title, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
            let trampoline = NotesMenuAction {
                Task { await nav.removeMemberships(ids, from: source) }
            }
            remove.target = trampoline
            remove.representedObject = trampoline
            menu.addItem(remove)
        }
        return menu
    }
}
