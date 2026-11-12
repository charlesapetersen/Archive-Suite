import SwiftUI
import ArchiveCore

/// Options ▸ Item types (W40.suite-item-types). Box and Folder are item types, tagged `Box` and `Folder`;
/// colour is the user's choice. Two settings, both app-side, neither ever written to a file: the list
/// marker's colour per type, and which colour meant which type in this folder's older material.
struct ItemTypeSettingsSection: View {
    @ObservedObject private var activeRoot = ActiveRootItemTypes.shared
    /// Bumped after a write so the pickers re-read UserDefaults.
    @State private var revision = 0

    var body: some View {
        Section {
            ForEach(ItemType.allCases, id: \.self) { type in
                colourPicker("\(type.displayName) marker", selection: markerBinding(type))
                    .accessibilityIdentifier("ar.settings.itemTypeMarker.\(type.rawValue.lowercased())")
            }
            if let id = activeRoot.rootID {
                Text("Older material in “\(activeRoot.rootName ?? "this folder")”")
                    .font(.callout)
                ForEach(ItemType.allCases, id: \.self) { type in
                    colourPicker("\(type.displayName) was marked", selection: rootBinding(type, root: id))
                        .accessibilityIdentifier("ar.settings.itemTypeRoot.\(type.rawValue.lowercased())")
                }
            }
        } header: {
            Text("Item types")
        } footer: {
            Text("A box or folder photo is tagged “Box” or “Folder”. The marker colour is how the list shows "
               + "each type; with none, the list shows the type's name. Material made before the tags may "
               + "carry only a Finder colour: say here which colour meant which type in this folder. "
               + "Nothing here writes to your files.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .id(revision)
    }

    private func colourPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(0)
            ForEach(FinderLabel.allCases, id: \.self) { label in
                Text(label.tokenName).tag(label.rawValue)
            }
        }
    }

    private func markerBinding(_ type: ItemType) -> Binding<Int> {
        Binding(
            get: { ItemTypePreferences.markerColours().colour(for: type)?.rawValue ?? 0 },
            set: { ItemTypePreferences.setMarkerColour(FinderLabel(labelNumber: $0), for: type); revision += 1 })
    }

    private func rootBinding(_ type: ItemType, root: UUID) -> Binding<Int> {
        Binding(
            get: { ItemTypePreferences.rootColours(for: root)?.colour(for: type)?.rawValue ?? 0 },
            set: { value in
                var colours = ItemTypePreferences.rootColours(for: root) ?? .none
                colours.setColour(FinderLabel(labelNumber: value), for: type)
                ItemTypePreferences.setRootColours(colours, for: root)
                revision += 1
            })
    }
}
