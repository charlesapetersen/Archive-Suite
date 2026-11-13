import SwiftUI
import AppKit

/// One tag as a chip, in SwiftUI, drawn to `TagChips`' metrics: the chip a tag has in the Reader's list, so a tag looks
/// the same in a list, a tag bar and a filter field in either app (W40.suite-reader-notes-consistency; owner, Notes
/// session 2 row 13: "with the tags shown in it as in the Reader's list"). With `onRemove` it ends in a ✕ that removes
/// the tag; the chip grows by the ✕ and keeps its padding.
public struct TagChip: View {
    let title: String
    let font: NSFont
    let removeIdentifier: String?
    let onRemove: (() -> Void)?

    public init(_ title: String, font: NSFont = .systemFont(ofSize: NSFont.systemFontSize),
                removeIdentifier: String? = nil, onRemove: (() -> Void)? = nil) {
        self.title = title
        self.font = font
        self.removeIdentifier = removeIdentifier
        self.onRemove = onRemove
    }

    /// The chip's height for `font`: one line of chips in a list.
    public static func height(for font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)) -> CGFloat {
        TagChips.chipHeight(for: font)
    }

    public var body: some View {
        let padding = TagChips.horizontalPadding(for: font)
        HStack(spacing: 3) {
            Text(title).font(Font(font)).lineLimit(1).truncationMode(.tail)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: max(8, font.pointSize - 4), weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Remove \(title)")
                .accessibilityLabel("Remove \(title)")
                .accessibilityIdentifier(removeIdentifier ?? "")
            }
        }
        .padding(.leading, padding)
        .padding(.trailing, onRemove == nil ? padding : padding / 2)
        .frame(height: TagChips.chipHeight(for: font))
        .background(RoundedRectangle(cornerRadius: TagChips.cornerRadius).fill(Color(nsColor: TagChips.fill)))
    }
}
