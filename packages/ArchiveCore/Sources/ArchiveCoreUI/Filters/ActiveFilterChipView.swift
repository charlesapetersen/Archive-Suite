import SwiftUI

/// One filter or search in effect, in a filter bar's In effect row (the Reader's W40.fix-reader-filter-bar, Notes'
/// W40.fix-notes-clear-all-advanced; one view for both since W40.suite-reader-notes-consistency). The whole chip is
/// its ✕, one control for the keyboard and VoiceOver as for the mouse.
public struct ActiveFilterChipView: View {
    let label: String
    /// What the filter does, for the tooltip ("In effect: <phrase>. Click to remove it.").
    let phrase: String
    let identifier: String
    let remove: () -> Void

    public init(label: String, phrase: String, identifier: String, remove: @escaping () -> Void) {
        self.label = label
        self.phrase = phrase
        self.identifier = identifier
        self.remove = remove
    }

    public var body: some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(label).lineLimit(1).truncationMode(.middle)
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.45)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 320)
        .help("In effect: \(phrase). Click to remove it.")
        .accessibilityLabel("Remove \(label)")
        .accessibilityIdentifier(identifier)
    }
}
