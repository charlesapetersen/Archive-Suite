import SwiftUI

/// The left navigation sidebar. A navigable folder tree rooted at the archive root — selecting a
/// folder scopes the list to that subtree; "All Files" clears the scope. (The Smart Folders section
/// is added in Milestone B.) Read-only navigation: it only sets the in-memory filter's `pathPrefix`.
struct SidebarView: View {
    @ObservedObject var model: NavigationModel
    static let allFilesTag = "\u{0}ALL"
    static let smartPrefix = "SS:"

    /// The highlighted row tracks the model's *real* folder scope (get), and clicking a row performs
    /// the action (set). This keeps the highlight from going stale after the filter-bar "Clear",
    /// `restoreViewState` on launch, or a menu-driven `applySaved`, and makes "All Files" reliably clear
    /// the scope. Smart folders are actions: applying one snaps the highlight to the resulting scope.
    private var selection: Binding<String?> {
        Binding(
            get: { model.filter.pathPrefix ?? SidebarView.allFilesTag },
            set: { new in
                if let new, new.hasPrefix(SidebarView.smartPrefix) {
                    let id = String(new.dropFirst(SidebarView.smartPrefix.count))
                    if let s = model.savedSearches.searches.first(where: { $0.id.uuidString == id }) {
                        model.applySaved(s)   // applies the saved filter + OCR query
                    }
                } else {
                    model.setFolderScope(new == nil || new == SidebarView.allFilesTag ? nil : new)
                }
            })
    }

    var body: some View {
        List(selection: selection) {
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
