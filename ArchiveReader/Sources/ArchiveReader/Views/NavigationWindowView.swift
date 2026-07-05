import SwiftUI

/// The file-navigation window (Finder-Smart-Folder-like). Scaffolding for now.
/// M1 adds: Spotlight discovery, the results table (Document date · Name · Type · Tags · Read/Unread),
/// multi-level sort, the three filters, copy-links, mark-read, and the tag editor.
struct NavigationWindowView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Archive Reader")
                .font(.largeTitle.bold())
            Text("File navigation window — foundation scaffold.")
                .foregroundStyle(.secondary)
            Text("Spotlight browser, filters (subject · priority · read-state), tag editor, and\ncopy-links arrive in M1. The read-only domain core is already in place.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 820, minHeight: 520)
        .padding(40)
    }
}

#Preview {
    NavigationWindowView()
}
