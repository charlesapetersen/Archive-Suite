import SwiftUI

/// W40.reader-commands-table (owner's Reader notes, 2026-11-10, point 14): the one place each command's name,
/// key and help text are written. The menus (`ArchiveReaderCommands`), the toolbars, the preview sheet's buttons
/// and the document window all read them here, so moving a key moves it everywhere. Before this, a key was
/// written beside each control that showed it, and when ⌥⌘C went to Copy Link(s) the preview sheet kept binding
/// ⌥⌘C to the cleaned copy and three tooltips kept naming it.
///
/// `ReaderCommandTableTests` fails on two commands sharing a key where both can answer it, on a menu item whose
/// key or name differs from the table, and on help text anywhere in the app that names a key the table does not
/// bind. A command with `reserved` set holds its key for an item still to come, so nothing else takes it.
struct CommandKey: Hashable, Sendable {
    let character: Character
    let modifiers: EventModifiers

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers = .command) {
        character = key.character
        self.modifiers = modifiers
    }

    var shortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(character), modifiers: modifiers) }

    /// The key as a menu shows it, modifiers in the Mac's order: ⌃⌥⇧⌘, then the key ("⇧⌘C").
    var glyph: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.glyph(of: character)
    }

    static func glyph(of character: Character) -> String {
        switch character {
        case KeyEquivalent.upArrow.character: return "↑"
        case KeyEquivalent.downArrow.character: return "↓"
        case KeyEquivalent.leftArrow.character: return "←"
        case KeyEquivalent.rightArrow.character: return "→"
        case KeyEquivalent.escape.character: return "Esc"
        case KeyEquivalent.space.character: return "Space"
        case "-": return "−"
        default: return String(character).uppercased()
        }
    }

    static func == (a: CommandKey, b: CommandKey) -> Bool {
        a.character == b.character && a.modifiers.rawValue == b.modifiers.rawValue
    }
    func hash(into h: inout Hasher) { h.combine(character); h.combine(modifiers.rawValue) }
}

/// Where a command's key is answered. The menu bar answers in every window, so a key in another context must
/// not be one the menu bar binds to a different command.
enum CommandContext: Hashable, Sendable, CaseIterable {
    case menuBar
    /// The preview sheet's own buttons (↑/↓/←/→, Esc), over the navigation window.
    case previewSheet
    /// The document window's own controls: Reset Zoom, the find bar.
    case documentWindow
    /// Keys the file list answers itself while it has the keyboard (bare ], [, \, Space).
    case list
}

enum ReaderCommand: String, CaseIterable, Sendable {
    // View
    case showSidebar, showTagCloud, showInspector, showJPEG
    // Edit
    case copyExact, copyCleaned, copyPageLink, options
    // File
    case chooseFolder, rescan, saveSearch, connectImproveOCR
    // Selection
    case open, preview, revealInFinder, copyLinks, copyArchiveLinks, selectRun, nextUnread, previousUnread
    // Tags
    case markRead, markUnread, markReadAndNext, renameTag, findSimilarTags, toggleFlag, undoTagChange, redoTagChange,
         togglePoorOCR, improveOCR
    // Sort & Filter
    case clearAll, focusTagFilter, searchOCRText, advancedSearch, showPoorOCROnly
    // Document
    case previousPage, nextPage, focusImagePane, focusTextPane, zoomIn, zoomOut, fitPage, find, findNext, findPrevious
    // Preview turns a page with ⌘L / ⌘R, which are Focus Tag Filter and Mark Read here, so the turn adds ⌃
    // (W40.reader-view-rotate).
    case rotateLeft, rotateRight, resetRotation
    // The document window's own controls
    case resetZoom, endFind
    // The preview sheet's own buttons
    case previewPreviousFile, previewNextFile, previewPreviousPage, previewNextPage, previewDone
    // The list's bare keys
    case listNextUnread, listPreviousUnread, listMarkReadAndNext, listPreview
    // Preview's page views, on Preview's keys ⌥⌘2 / ⌥⌘6 (W40.reader-page-views). Show/Hide Thumbnails is one
    // item that toggles the sidebar, as Preview's ⌥⌘2 does (W40.reader-thumbnails-toggle).
    case showThumbnails, contactSheet
    // The image page's right-click menu, beside Reveal in Finder (W40.reader-image-context-menu)
    case copyImage

    var context: CommandContext {
        switch self {
        case .resetZoom, .endFind: return .documentWindow
        case .previewPreviousFile, .previewNextFile, .previewPreviousPage, .previewNextPage, .previewDone:
            return .previewSheet
        case .listNextUnread, .listPreviousUnread, .listMarkReadAndNext, .listPreview: return .list
        default: return .menuBar
        }
    }

    /// Held for a later item: in the table so no other command takes the key, but bound nowhere yet.
    var reserved: Bool {
        false
    }

    /// The menu (or button) name. A Show/Hide pair is named by its Show half; `title(showing:)` gives the other.
    var title: String {
        switch self {
        case .showSidebar: return "Show Sidebar"
        case .showTagCloud: return "Show Tag Cloud"
        case .showInspector: return "Show Inspector"
        case .showJPEG: return "Show JPEG Image"
        case .copyExact: return "Copy"
        case .copyCleaned: return "Copy Cleaned for Prose"
        case .copyPageLink: return "Copy Archive Link to This Page"
        case .options: return "Settings…"
        case .chooseFolder: return "Choose Archive Folder…"
        case .rescan: return "Rescan Archive Folder"
        case .saveSearch: return "Save Current Search…"
        case .connectImproveOCR: return "Connect Improve OCR Folder…"
        case .open: return "Open in Document Window"
        case .preview: return "Preview"
        case .revealInFinder: return "Reveal in Finder"
        case .copyLinks: return "Copy Link(s)"
        case .copyArchiveLinks: return "Copy Archive Link(s)"
        case .selectRun: return "Select Document Run"
        case .nextUnread: return "Next Unread"
        case .previousUnread: return "Previous Unread"
        case .markRead: return "Mark Read"
        case .markUnread: return "Mark Unread"
        case .markReadAndNext: return "Mark Read & Next Unread"
        case .renameTag: return "Rename Tag…"
        case .findSimilarTags: return "Find Similar Tags…"
        case .toggleFlag: return "Toggle Flag"
        case .undoTagChange: return "Undo Tag Change"
        case .redoTagChange: return "Redo Tag Change"
        case .togglePoorOCR: return "Flag as Poor OCR"
        case .improveOCR: return "Improve OCR…"
        case .clearAll: return "Clear All"
        case .focusTagFilter: return "Focus Tag Filter"
        case .searchOCRText: return "Search OCR Text"
        case .advancedSearch: return "Advanced Search…"
        case .showPoorOCROnly: return "Show Poor OCR Only"
        case .previousPage: return "Previous Page in Segment"
        case .nextPage: return "Next Page in Segment"
        case .focusImagePane: return "Focus Image Page"
        case .focusTextPane: return "Focus Text Page"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .fitPage: return "Fit Page"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .resetZoom: return "Reset Zoom"
        case .endFind: return "Done"
        case .previewPreviousFile: return "Previous File"
        case .previewNextFile: return "Next File"
        case .previewPreviousPage: return "Previous Page"
        case .previewNextPage: return "Next Page"
        case .previewDone: return "Done"
        case .listNextUnread: return "Next Unread"
        case .listPreviousUnread: return "Previous Unread"
        case .listMarkReadAndNext: return "Mark Read & Next Unread"
        case .listPreview: return "Preview"
        case .rotateLeft: return "Rotate Left"
        case .rotateRight: return "Rotate Right"
        case .resetRotation: return "Reset Rotation"
        case .showThumbnails: return "Show Thumbnails"
        case .contactSheet: return "Contact Sheet"
        case .copyImage: return "Copy Image"
        }
    }

    /// A Show/Hide pair's name as the menu shows it now.
    func title(showing: Bool) -> String {
        switch self {
        case .showJPEG: return showing ? "Show PDF Image" : title
        default:
            guard showing, title.hasPrefix("Show ") else { return title }
            return "Hide " + title.dropFirst("Show ".count)
        }
    }

    var key: CommandKey? {
        switch self {
        // ⌃⌘S is the Mac's Show/Hide Sidebar, and the tag cloud takes the T beside it; ⌥⌘T is the Mac's
        // Show/Hide Toolbar (W40.fix-suite-shortcuts).
        case .showSidebar: return CommandKey("s", [.command, .control])
        case .showTagCloud: return CommandKey("t", [.command, .control])
        // As in Archive Notes, where ⌘I is Italic. ⌘I was Edit Info's key and is now free.
        case .showInspector: return CommandKey("i", [.command, .option])
        case .showJPEG: return CommandKey("j", [.command, .option])
        // ⌘C is the standard Edit ▸ Copy, which reaches the viewer through the responder chain (W48.reader-copy-shortcut).
        case .copyExact: return CommandKey("c")
        // Owner, 2026-11-08: ⇧⌘C cleans prose; Copy Link(s) takes ⌥⌘C.
        case .copyCleaned: return CommandKey("c", [.command, .shift])
        // ⌘L is Focus Tag Filter and ⇧⌘L Copy Archive Link(s), so the page link takes the remaining L.
        case .copyPageLink: return CommandKey("l", [.command, .option])
        case .options: return CommandKey(",")
        case .chooseFolder: return CommandKey("o", [.command, .shift])
        // ⌘R is Mark Read.
        case .rescan: return CommandKey("r", [.command, .option])
        case .saveSearch, .connectImproveOCR, .improveOCR, .showPoorOCROnly: return nil
        case .open: return CommandKey("o")
        case .preview: return CommandKey("y")
        case .revealInFinder: return CommandKey("r", [.command, .shift])
        case .copyLinks: return CommandKey("c", [.command, .option])
        case .copyArchiveLinks: return CommandKey("l", [.command, .shift])
        case .selectRun: return nil
        case .nextUnread: return CommandKey("]")
        case .previousUnread: return CommandKey("[")
        case .markRead: return CommandKey("r")
        case .markUnread: return CommandKey("u")
        case .markReadAndNext: return CommandKey("m", [.command, .shift])
        case .renameTag, .findSimilarTags: return nil
        case .toggleFlag: return CommandKey("f", [.command, .shift])
        // P for Poor; ⌘P stays the Mac's Print.
        case .togglePoorOCR: return CommandKey("p", [.command, .control])
        case .undoTagChange: return CommandKey("z")
        case .redoTagChange: return CommandKey("z", [.command, .shift])
        case .clearAll: return CommandKey("k", [.command, .shift])
        case .focusTagFilter: return CommandKey("l")
        case .searchOCRText: return CommandKey("f", [.command, .option])
        case .advancedSearch: return CommandKey("f", [.command, .option, .shift])
        case .previousPage: return CommandKey(.upArrow, [.command, .shift])
        case .nextPage: return CommandKey(.downArrow, [.command, .shift])
        case .focusImagePane: return CommandKey(.leftArrow, [.command, .option])
        case .focusTextPane: return CommandKey(.rightArrow, [.command, .option])
        case .zoomIn: return CommandKey("+")
        case .zoomOut: return CommandKey("-")
        case .fitPage: return CommandKey("0")
        case .find: return CommandKey("f")
        case .findNext: return CommandKey("g")
        case .findPrevious: return CommandKey("g", [.command, .shift])
        case .resetZoom: return CommandKey("0", [.command, .option])
        case .endFind, .previewDone: return CommandKey(.escape, [])
        case .previewPreviousFile: return CommandKey(.upArrow, [])
        case .previewNextFile: return CommandKey(.downArrow, [])
        case .previewPreviousPage: return CommandKey(.leftArrow, [])
        case .previewNextPage: return CommandKey(.rightArrow, [])
        case .listNextUnread: return CommandKey("]", [])
        case .listPreviousUnread: return CommandKey("[", [])
        case .listMarkReadAndNext: return CommandKey("\\", [])
        case .listPreview: return CommandKey(.space, [])
        case .rotateLeft: return CommandKey("l", [.command, .control])
        case .rotateRight: return CommandKey("r", [.command, .control])
        case .resetRotation: return nil
        case .showThumbnails: return CommandKey("2", [.command, .option])
        case .contactSheet: return CommandKey("6", [.command, .option])
        case .copyImage: return nil
        }
    }

    var shortcut: KeyboardShortcut? { key?.shortcut }
    var glyph: String { key?.glyph ?? "" }

    /// What the command does, without its key; `help` adds the key.
    private var summary: String? {
        switch self {
        case .showInspector: return "Show or hide the Inspector: the tags, date, quality and flag of the selected documents"
        case .showJPEG: return "Switch between the PDF's image and the JPEG original"
        case .copyExact: return "Copy the selected text exactly"
        case .copyCleaned: return "Copy the selected text cleaned for prose — joins lines, de-hyphenates"
        case .open: return "Open the selected documents for reading"
        case .preview: return "Preview the selection 2-up without opening it (Space or \(glyph))"
        case .copyLinks: return "Copy links to the selected files"
        case .copyArchiveLinks: return "Copy durable archive links"
        case .markRead: return "Mark the selected documents as read"
        case .markUnread: return "Mark the selected documents as unread"
        case .toggleFlag: return "Flag or unflag the selection — app-only, never written to the file"
        case .togglePoorOCR: return "Mark the selection's OCR as not good enough (the OCR Poor tag), or remove the mark"
        case .improveOCR: return "Open Archive Processor's Improve OCR dialog on the selection, to read it again with a better reader"
        case .connectImproveOCR: return "Choose the folder the Reader and Archive Processor share for Improve OCR"
        case .undoTagChange: return "Undo the last tag change"
        case .advancedSearch: return "Advanced Search: combine rules on text, tags, dates, folders and more"
        case .previousPage: return "Previous page in this segment"
        case .nextPage: return "Next page in this segment"
        case .find: return "Search for text in this document"
        case .findNext: return "Next match"
        case .findPrevious: return "Previous match"
        case .resetZoom:
            return "Fit both pages to their panes and the text to its normal size (\(glyph); \(Self.fitPage.glyph) fits the focused page alone)"
        case .rotateLeft: return "Turn the image page a quarter turn left, in this view only — the file is not changed"
        case .rotateRight: return "Turn the image page a quarter turn right, in this view only — the file is not changed"
        case .resetRotation: return "Show the image page as it is in the file"
        case .showThumbnails: return "Show or hide a thumbnail of each scan of the open files beside the page"
        case .contactSheet: return "Show every PDF page of the open files as a numbered tile"
        case .copyImage: return "Copy the image page as it is shown, turned as the viewer turns it"
        case .previewPreviousFile: return "Previous file in the list (\(glyph); ⇧\(glyph) adds it to the selection)"
        case .previewNextFile: return "Next file in the list (\(glyph); ⇧\(glyph) adds it to the selection)"
        case .previewPreviousPage: return "Previous page in the selection"
        case .previewNextPage: return "Next page in the selection"
        case .previewDone: return "Close preview (\(glyph) or Space)"
        default: return nil
        }
    }

    /// The tooltip: what the command does and its key, "(⇧⌘C)", unless the summary already names its keys.
    var help: String {
        let what = summary ?? title
        guard let key, !what.contains(key.glyph) else { return what }
        return "\(what) (\(key.glyph))"
    }
}

extension View {
    /// Binds the command's key from the table, or nothing for a command without one. A bare Esc is bound as
    /// the cancel action, which also answers ⌘. as a Mac sheet does.
    @ViewBuilder func keyboardShortcut(_ command: ReaderCommand) -> some View {
        if command.key == CommandKey(.escape, []) {
            keyboardShortcut(.cancelAction)
        } else if let shortcut = command.shortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}
