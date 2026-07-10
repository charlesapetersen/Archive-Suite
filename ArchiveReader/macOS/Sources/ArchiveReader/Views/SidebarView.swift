import SwiftUI

/// The left navigation sidebar. A navigable folder tree rooted at the archive root — selecting a
/// folder scopes the list to that subtree; "All Files" clears the scope. A Smart Folders section
/// (saved searches) sits above it. Read-only navigation: it only sets the in-memory filter's
/// `pathPrefix` (or applies a saved search as a base scope) — it never writes anything to disk.
///
/// Selection uses a real `@State` (`List` + `OutlineGroup` drive it natively and reliably) plus a
/// **two-way sync**: clicking a row performs the action, and any *external* change (filter-bar
/// "Clear", `restoreViewState` on launch, scope exit) is mirrored back into the highlight. A
/// computed `Binding` was tried instead but its `set` did not fire for `OutlineGroup` tree rows —
/// clicks moved the highlight without scoping the list — so the two-way `@State` is the robust
/// form. `setFolderScope`'s no-op guard makes the sync loop-safe.
///
/// Smart folders are a **durable highlight**: selecting one enters a base scope that persists until
/// the user selects a folder / All Files (which exits the scope). The sidebar reflects this —
/// the smart-folder row stays highlighted while the scope is active.
struct SidebarView: View {
    @ObservedObject var model: NavigationModel
    static let allFilesTag = "\u{0}ALL"
    static let smartPrefix = "SS:"

    @State private var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(model.savedSearches.searches) { s in
                    // Badge is tag-facet-only, so hide it for smart folders that also carry an OCR query
                    // (the opened list is a subset — the count would over-state and contradict it).
                    row(name: s.name, systemImage: "folder.badge.gearshape",
                        count: s.fullTextQuery.isEmpty ? model.smartFolderCounts[s.id] : nil)
                        .tag(SidebarView.smartPrefix + s.id.uuidString)
                        .contextMenu {
                            Button("Rename…") { model.renamingSearch = s }
                            Button("Delete", role: .destructive) { model.savedSearches.delete(s.id) }
                        }
                }
                .onMove { from, to in model.savedSearches.move(fromOffsets: from, toOffset: to) }
            } header: {
                HStack {
                    Text("Smart Folders")
                    Spacer()
                    Button { model.showingSaveDialog = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("Save the current filters as a smart folder")
                }
            }

            Section("Folders") {
                row(name: "All Files", systemImage: "tray.full", count: model.folderTree?.fileCount)
                    .tag(SidebarView.allFilesTag)
                if let root = model.folderTree {
                    OutlineGroup(root.children, children: \.childrenOrNil) { node in
                        row(name: node.name, systemImage: "folder", count: node.fileCount)
                            .tag(node.path)
                            .help(node.path)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onAppear { syncSelectionFromModel() }
        .onChange(of: selection) { _, new in applySelection(new) }
        .onChange(of: model.filter.pathPrefix) { _, _ in syncSelectionFromModel() }
        .onChange(of: model.scope?.id) { _, _ in syncSelectionFromModel() }
    }

    /// Perform the action for a newly-clicked row: enter a smart-folder scope, or scope to a folder.
    private func applySelection(_ new: String?) {
        if let new, new.hasPrefix(SidebarView.smartPrefix) {
            let id = String(new.dropFirst(SidebarView.smartPrefix.count))
            if let s = model.savedSearches.searches.first(where: { $0.id.uuidString == id }) {
                model.applyScope(s)
            }
        } else {
            model.setFolderScope(new == nil || new == SidebarView.allFilesTag ? nil : new)
        }
    }

    /// Mirror the model's scope / folder into the sidebar highlight. When a smart folder is the
    /// active scope, highlight it; otherwise highlight the folder / All Files.
    private func syncSelectionFromModel() {
        let want = model.scope.map { SidebarView.smartPrefix + $0.id.uuidString }
            ?? (model.filter.pathPrefix ?? SidebarView.allFilesTag)
        if selection != want { selection = want }
    }

    private func row(name: String, systemImage: String, count: Int?) -> some View {
        HStack {
            Label(name, systemImage: systemImage)
            Spacer(minLength: 6)
            if let count {
                Text("\(count)").foregroundStyle(.secondary).font(.caption).monospacedDigit()
            }
        }
    }
}
