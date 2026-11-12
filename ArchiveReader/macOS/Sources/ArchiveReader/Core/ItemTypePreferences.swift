// ItemTypePreferences.swift — W40.suite-item-types: the Reader's two item-type colour settings.
//
// A Box or Folder item is its `Box`/`Folder` tag (SPEC/tag-format.md §Item type). Colour is the user's:
// - the list marker's colour per type (Options ▸ Item types), none by default, when a type glyph is shown;
// - per archive root, which Finder colour meant which type in material marked before the tokens existed,
//   asked once when a root is chosen and changeable in Options. The Reader reads a type through it and
//   never writes it to a file.
// Both live app-side in UserDefaults, never in the corpus; choosing them writes nothing to any file.

import AppKit
import Combine
import ArchiveCore

enum ItemTypePreferences {
    /// The list marker's colour per type, as Finder label numbers (0 or absent: none).
    static let markerBoxKey = "ar.itemTypeMarker.box"
    static let markerFolderKey = "ar.itemTypeMarker.folder"
    /// `[preference GUID: ["box": label, "folder": label]]`; a root with no entry was never asked.
    static let rootColoursKey = "ar.itemTypeColoursByRoot"

    /// Posted on the main thread after either setting changes, so the list re-reads its rows.
    static let didChange = Notification.Name("ArchiveReader.itemTypePreferencesDidChange")

    static func markerColours(_ d: UserDefaults = .standard) -> ItemTypeColors {
        ItemTypeColors(box: FinderLabel(labelNumber: d.integer(forKey: markerBoxKey)),
                       folder: FinderLabel(labelNumber: d.integer(forKey: markerFolderKey)))
    }

    static func setMarkerColour(_ colour: FinderLabel?, for type: ItemType, _ d: UserDefaults = .standard) {
        d.set(colour?.rawValue ?? 0, forKey: type == .box ? markerBoxKey : markerFolderKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The colours a root's older material used for each type; nil when the user was never asked.
    static func rootColours(for root: UUID?, _ d: UserDefaults = .standard) -> ItemTypeColors? {
        guard let root,
              let all = d.dictionary(forKey: rootColoursKey) as? [String: [String: Int]],
              let entry = all[root.uuidString.lowercased()] else { return nil }
        return ItemTypeColors(box: FinderLabel(labelNumber: entry["box"]),
                              folder: FinderLabel(labelNumber: entry["folder"]))
    }

    static func setRootColours(_ colours: ItemTypeColors, for root: UUID, _ d: UserDefaults = .standard) {
        var all = d.dictionary(forKey: rootColoursKey) as? [String: [String: Int]] ?? [:]
        all[root.uuidString.lowercased()] = ["box": colours.box?.rawValue ?? 0,
                                             "folder": colours.folder?.rawValue ?? 0]
        d.set(all, forKey: rootColoursKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// A display colour for a Finder label, for the list marker and Options.
    static func nsColor(_ label: FinderLabel) -> NSColor {
        switch label {
        case .gray: return .systemGray
        case .green: return .systemGreen
        case .purple: return .systemPurple
        case .blue: return .systemBlue
        case .yellow: return .systemYellow
        case .red: return .systemRed
        case .orange: return .systemOrange
        }
    }
}

/// The archive root Options edits the older-material colours of: the navigation model publishes its
/// root's preference GUID here, in memory. Only an answer the user gives is stored, keyed by that GUID.
@MainActor
final class ActiveRootItemTypes: ObservableObject {
    static let shared = ActiveRootItemTypes()
    @Published var rootID: UUID?
    @Published var rootName: String?
}
