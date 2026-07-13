import SwiftUI

/// Detail-pane "Locations" section (06-viewers §5, W6-S5): every folder the selected item belongs to,
/// each row a shortcut to that folder plus a **Remove** control that runs the delete-last-instance-
/// guarded removal. A replicated item (in ≥2 folders) shows all its homes; removing the *last* one
/// routes through `NotesNavigationModel.removeMembership`, which surfaces the mandatory §3.6
/// confirmation before anything is deleted.
struct LocationsInspector: View {
    @ObservedObject var nav: NotesNavigationModel
    let itemId: UUID

    var body: some View {
        let folders = nav.locations(of: itemId)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: folders.count > 1 ? "link" : "folder")
                    .foregroundStyle(folders.count > 1 ? Color.accentColor : .secondary)
                Text(folders.count > 1 ? "Replicated — in \(folders.count) folders"
                                       : (folders.isEmpty ? "Locations" : "Location"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if folders.isEmpty {
                Text("Not in any folder — reachable under All Notes.")
                    .font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(folders) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Button(folder.name) { nav.model.setFolderScope(folder.id) }
                            .buttonStyle(.link).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Button {
                            Task { await nav.removeMembership(itemId, from: folder.id) }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from “\(folder.name)”")
                        .accessibilityIdentifier("an.locations.remove")
                    }
                    .font(.caption)
                }
            }
        }
        .accessibilityIdentifier("an.detail.locations")
    }
}
