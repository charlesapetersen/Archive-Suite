import SwiftUI
import AppKit

/// Pure, testable presentation values for a Zotero chip (label, glyph, a11y id, help).
/// Extracted from the SwiftUI view so the display logic can be unit-tested without
/// instantiating a view (00-overview §D.5). See `ZoteroChipPresentationTests`.
struct ZoteroChipPresentation: Equatable {
    var label: String
    var systemImage: String
    var accessibilityID: String
    var help: String

    init(ref: ZoteroRef) {
        if let citation = ref.citation, !citation.isEmpty {
            label = citation
        } else {
            label = ref.itemKey
        }
        systemImage = (ref.kind == .attachment) ? "paperclip" : "book.closed"
        accessibilityID = "ar.zotero.chip.\(ref.itemKey)"
        help = ref.citation ?? ref.selectLink
    }
}

/// A clickable Zotero-reference pill. Clicking opens Zotero (and selects the item)
/// via `NSWorkspace` — this works even when our cached metadata is stale or Zotero
/// is closed (macOS launches it), so the chip is always useful. Reusable at note
/// level (W6 inspector) and inside the clipboard-attach banner.
///
/// A trailing spinner shows while a fetch `Task` for the ref is in flight; a small
/// ⚠︎ shows if the last fetch failed (the link still opens).
struct ZoteroChipView: View {
    let ref: ZoteroRef
    var isFetching: Bool = false
    var didFail: Bool = false
    /// Override the open action (tests / previews); defaults to `NSWorkspace.open`.
    var onOpen: ((ZoteroRef) -> Void)? = nil

    private var presentation: ZoteroChipPresentation { ZoteroChipPresentation(ref: ref) }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 4) {
                Image(systemName: presentation.systemImage)
                Text(presentation.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if isFetching {
                    ProgressView().controlSize(.mini)
                } else if didFail {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help(presentation.help)
        .accessibilityIdentifier(presentation.accessibilityID)
    }

    private func open() {
        if let onOpen {
            onOpen(ref)
            return
        }
        if let url = URL(string: ref.selectLink) {
            NSWorkspace.shared.open(url)
        }
    }
}
