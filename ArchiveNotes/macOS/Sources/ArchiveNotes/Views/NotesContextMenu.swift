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

/// Builds the item-row context menu for the Notes table (06-viewers §5, W6-S5): **Add to Folder ▸**
/// (replicate) and **Move to Folder ▸** over the normal-folder list, plus, when the list is scoped to
/// a normal folder, **Remove from “<folder>”** (delete-last-instance guarded). This is the reliable,
/// keyboard/accessibility path for the same operations drag offers.
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
