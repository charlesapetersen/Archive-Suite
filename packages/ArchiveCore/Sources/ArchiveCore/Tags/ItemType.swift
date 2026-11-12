import Foundation

// Item type (W40.suite-item-types, owner's Reader notes 2026-11-10, point 15; SPEC/tag-format.md §Item type).
// A box photo and a folder photo are item types, written as the reserved tag tokens `Box` and `Folder`.
// The Finder colour label is the user's own choice: a display setting, off by default, never the record
// of the type. Material marked before the type had its own token is read through a per-root
// `ItemTypeColors` (which colour meant which type), set by the user once.

/// What a file is when it is not a document: a photo of a box label or of a folder label. The token is
/// the same word as the page-2 Classification (`Box` / `Folder`).
public enum ItemType: String, Sendable, CaseIterable, Codable {
    case box = "Box"
    case folder = "Folder"

    /// The reserved tag token, matched by its exact spelling (a subject `box` is a subject).
    public var tokenName: String { rawValue }
    public var displayName: String { rawValue }

    /// The type a whole tag token names, or nil. Exact spelling: `" Box "` or `box` is a subject, so the
    /// token a type edit removes is always exactly the one the parser read.
    public init?(token: String) {
        self.init(rawValue: token)
    }
}

/// The seven Finder colour labels, by `.labelNumberKey` value (0 is no label).
public enum FinderLabel: Int, Sendable, CaseIterable, Codable {
    case gray = 1, green = 2, purple = 3, blue = 4, yellow = 5, red = 6, orange = 7

    /// The colour-name token Finder keeps in the tag array beside the label.
    public var tokenName: String {
        switch self {
        case .gray: return "Gray"
        case .green: return "Green"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .orange: return "Orange"
        }
    }

    public init?(labelNumber: Int?) {
        guard let labelNumber, let l = FinderLabel(rawValue: labelNumber) else { return nil }
        self = l
    }

    /// Whether `s` is a Finder colour name in the exact spelling Finder writes (`Green`, not `green`).
    public static func isColourName(_ s: String) -> Bool {
        allCases.contains { $0.tokenName == s }
    }
}

/// A Finder colour for each item type, or none. Two uses, kept apart by the apps that hold them:
/// - a user's display choice (the colour the Processor writes, the Reader's list marker), `.none` for a
///   new user;
/// - per archive root, which colour meant which type in material marked before the `Box`/`Folder`
///   tokens existed. The Reader reads a type from the colour only through this, and never writes it.
public struct ItemTypeColors: Sendable, Equatable, Codable {
    public var box: FinderLabel?
    public var folder: FinderLabel?

    public init(box: FinderLabel? = nil, folder: FinderLabel? = nil) {
        self.box = box; self.folder = folder
    }

    /// No colour for either type.
    public static let none = ItemTypeColors()
    /// Red for a box, Purple for a folder: how the Processor marked them before W40.suite-item-types.
    public static let redBoxPurpleFolder = ItemTypeColors(box: .red, folder: .purple)

    public var isNone: Bool { box == nil && folder == nil }

    public func colour(for type: ItemType) -> FinderLabel? {
        type == .box ? box : folder
    }

    public mutating func setColour(_ colour: FinderLabel?, for type: ItemType) {
        if type == .box { box = colour } else { folder = colour }
    }

    /// The type a Finder label means, or nil. One colour given to both types means neither: it cannot
    /// say which.
    public func type(forLabel labelNumber: Int?) -> ItemType? {
        guard let label = FinderLabel(labelNumber: labelNumber) else { return nil }
        let matches = ItemType.allCases.filter { colour(for: $0) == label }
        return matches.count == 1 ? matches[0] : nil
    }
}
