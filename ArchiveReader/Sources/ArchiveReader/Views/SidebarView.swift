import SwiftUI

/// The left navigation sidebar. A navigable folder tree rooted at the archive root — selecting a
/// folder scopes the list to that subtree; "All Files" clears the scope. (The Smart Folders section
/// is added in Milestone B.) Read-only navigation: it only sets the in-memory filter's `pathPrefix`.
struct SidebarView: View {
    @ObservedObject var model: NavigationModel
    /// Selected sidebar row: the sentinel `allFilesTag` or a folder's absolute path.
    @State private var selection: String? = SidebarView.allFilesTag
    static let allFilesTag = "\u{0}ALL"

    var body: some View {
        List(selection: $selection) {
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
        .onChange(of: selection) { _, new in
            model.setFolderScope(new == nil || new == SidebarView.allFilesTag ? nil : new)
        }
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
