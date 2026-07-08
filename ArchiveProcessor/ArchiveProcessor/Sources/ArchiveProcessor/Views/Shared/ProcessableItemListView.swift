import SwiftUI

/// Generic list of `ProcessableItem`s shared by the Files and Live-Capture panes. Mirrors the Files
/// `fileList` structure (a `ScrollViewReader` over a `LazyVStack`), with selection-driven inline
/// disclosure and an injected action handler. Keyboard handling stays with the caller (the Files pane's
/// review-mode nav is Files-specific), so this view only owns tap-to-expand + scroll-to-focus.
struct ProcessableItemListView: View {
    let items: [any ProcessableItem]
    /// The expanded/selected item id (inline disclosure). Two-way so the caller can also drive it.
    @Binding var selection: String?
    var badgeStyle: StatusBadge.Style = .icon
    var showTagsList: Bool = false
    /// Optional focus ring id (e.g. Files review focus), scrolled into view when it changes.
    var focusedID: String? = nil
    let actions: ProcessableItemActions

    var body: some View {
        ScrollViewReader { proxy in
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(items, id: \.itemID) { item in
                    ProcessableItemRow(
                        item: item,
                        badgeStyle: badgeStyle,
                        isExpanded: selection == item.itemID,
                        isFocused: focusedID == item.itemID,
                        showTagsList: showTagsList,
                        actions: actions)
                        .id(item.itemID)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = (selection == item.itemID) ? nil : item.itemID
                        }
                }
            }
            .onChange(of: focusedID) { _, new in
                if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }
}
