import Foundation
import ArchiveCore

/// W40.suite-item-types: the Finder colour the user chose for Box and Folder items (Settings ▸ Tagging),
/// none by default. The item type itself is always written as its `Box`/`Folder` token; this colour is
/// only the user's display choice, written as the Finder label beside it when one is set.
enum ItemTypeColourSetting {
    /// Headless test drivers only: colours used instead of the user's, held in memory so a driver never
    /// writes the app's real defaults. nil (always, outside a driver) reads the setting.
    nonisolated(unsafe) static var driverOverride: ItemTypeColors?

    nonisolated static func colour(for type: ItemType, _ d: UserDefaults = .standard) -> FinderLabel? {
        if let driverOverride { return driverOverride.colour(for: type) }
        return FinderLabel(labelNumber: d.integer(forKey: type == .box ? DefaultsKeys.itemTypeColourBox
                                                              : DefaultsKeys.itemTypeColourFolder))
    }

    /// The colour-name token for `type`'s chosen colour, or nil when the user chose none.
    nonisolated static func colorTag(for type: ItemType) -> String? { colour(for: type)?.tokenName }

    /// Every colour name the user gave a type, for telling the app's own colour token from a subject.
    nonisolated static var chosenColourNames: Set<String> {
        Set(ItemType.allCases.compactMap(colorTag(for:)))
    }
}
