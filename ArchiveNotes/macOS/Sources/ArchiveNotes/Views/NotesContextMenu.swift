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
    static func make(nav: NotesNavigationModel, selection: Set<UUID>) -> NSMenu? {
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
                            if let newID = await model.newItem(kind: summary.kind,
                                                               in: model.selectedFolderId,
                                                               from: templateId) {
                                nav.showingTemplates = false
                                nav.select(newID)
                            }
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

                let qualityMenu = NSMenu()
                for (title, value) in [("None", Optional<Int>.none), ("Quality 1", 1),
                                       ("Quality 2", 2), ("Quality 3", 3)] {
                    let item = NSMenuItem(title: title, action: #selector(NotesMenuAction.fire), keyEquivalent: "")
                    item.state = summary.quality == value ? .on : .off
                    let trampoline = NotesMenuAction { Task { await nav.setQuality(value, for: id) } }
                    item.target = trampoline
                    item.representedObject = trampoline
                    qualityMenu.addItem(item)
                }
                let setQuality = NSMenuItem(title: "Set Quality", action: nil, keyEquivalent: "")
                setQuality.submenu = qualityMenu
                menu.addItem(setQuality)
            }

            menu.addItem(.separator())

            let delete = NSMenuItem(title: "Delete…", action: #selector(NotesMenuAction.fire), keyEquivalent: "")
            let deleteAction = NotesMenuAction { nav.requestDeleteItem(id) }
            delete.target = deleteAction
            delete.representedObject = deleteAction
            menu.addItem(delete)
            menu.addItem(.separator())
        }

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
                // Guarded per item: replicants are removed quietly; a sole-instance surfaces the §3.6
                // confirmation. (Multi-select where several are sole-instances confirms one at a time.)
                Task { for id in ids { await nav.removeMembership(id, from: source) } }
            }
            remove.target = trampoline
            remove.representedObject = trampoline
            menu.addItem(remove)
        }
        return menu
    }
}
