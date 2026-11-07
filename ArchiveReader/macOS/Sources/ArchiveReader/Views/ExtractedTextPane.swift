import SwiftUI
import AppKit

/// Imperative handle to the extracted-text pane's text view — reading and clearing its selection, the way
/// `PDFPaneController` does for a PDF pane. Read-only: the view never edits the text.
///
/// W40.fix-reader-copy-text-pane: the pane was a selectable SwiftUI `Text`, whose selection nothing in the
/// app could read. Copy and Copy Cleaned for Prose took the image page's selection, and Edit ▸ Copy, which
/// the image pane validated, was greyed with text selected here.
@MainActor
final class ExtractedTextController {
    weak var textView: NSTextView?
    /// Edit ▸ Copy reaching this pane, and whether there is a selection to copy. Set by
    /// `DocumentViewerModel`; nil leaves NSTextView's own `copy:` in place. See `ExtractedTextView.copy(_:)`.
    var copySelection: (() -> Void)?
    var canCopySelection: (() -> Bool)?
    /// The user made a selection here (the view is first responder, so it is not find's doing). Set by
    /// `DocumentViewerModel`, which clears the image pane's selection so only one pane holds one.
    var userSelected: (() -> Void)?

    /// The selected text, verbatim (nil if nothing is selected here).
    func plainSelection() -> String? {
        guard let v = textView else { return nil }
        let r = v.selectedRange()
        guard r.location != NSNotFound, r.length > 0, NSMaxRange(r) <= (v.string as NSString).length else { return nil }
        let s = (v.string as NSString).substring(with: r)
        return s.isEmpty ? nil : s
    }

    /// The selection cleaned for prose. Plain text has no line boxes, so the cleaner works from the text
    /// alone (`paragraphFromLayout` has no layout to read here).
    func cleanedSelection(_ options: CopyTextOptions) -> String? {
        plainSelection().map { CopyTextCleaner.clean($0, options: options) }
    }

    func clearSelection() {
        guard let v = textView, v.selectedRange().length > 0 else { return }
        v.setSelectedRange(NSRange(location: 0, length: 0))
    }

    func focus() { textView?.window?.makeFirstResponder(textView) }
}

/// The right pane when a page pair has no OCR text page but its image page carries a text layer — a
/// single-page PDF, which is almost all of the corpus. Selectable plain text at the viewer's text size
/// (`DocumentViewerModel.textScale`), so Zoom In / Out on the text pane changes it
/// (W40.fix-reader-text-zoom: at a fixed `.body` font it did nothing visible). Read-only.
///
/// An AppKit text view, so its selection is the viewer's to copy (W40.fix-reader-copy-text-pane): Copy,
/// Copy Cleaned for Prose and the services all take it, and selecting here clears the image pane's.
///
/// Find highlights its matches as the PDF panes do, the current hit in the find colour
/// (W40.fix-reader-find-both-panes), and scrolls to that hit.
struct ExtractedTextPane: NSViewRepresentable {
    let text: String
    let scale: CGFloat
    var controller: ExtractedTextController? = nil
    /// The searched query and which of its matches is the current hit; nil = no find highlight.
    var find: (query: String, current: Int?)? = nil
    var id: String = ""

    static let baseSize = NSFont.systemFontSize
    static let inset = NSSize(width: 16, height: 16)
    static func font(scale: CGFloat) -> NSFont { .systemFont(ofSize: baseSize * scale) }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var controller: ExtractedTextController?
        var shown: (text: String, scale: CGFloat, query: String?, current: Int?)?

        func textViewDidChangeSelection(_ note: Notification) {
            guard let v = note.object as? NSTextView, v.selectedRange().length > 0,
                  v.window?.firstResponder === v else { return }
            controller?.userSelected?()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let view = ExtractedTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.usesFindBar = false
        view.drawsBackground = false
        view.textContainerInset = Self.inset
        view.delegate = context.coordinator
        if !id.isEmpty { view.setAccessibilityIdentifier(id) }
        update(view, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ExtractedTextView else { return }
        update(view, context: context)
    }

    private func update(_ view: ExtractedTextView, context: Context) {
        context.coordinator.controller = controller
        view.controller = controller
        controller?.textView = view
        let c = context.coordinator
        let changedText = c.shown?.text != text
        if changedText {
            // A new text replaces the storage, which drops the selection — wanted: it belonged to the old one.
            view.textStorage?.setAttributedString(NSAttributedString(string: text))
            view.scrollToBeginningOfDocument(nil)
        }
        if changedText || c.shown?.scale != scale {
            view.font = Self.font(scale: scale)
            view.textColor = .labelColor
        }
        if changedText || c.shown?.query != find?.query || c.shown?.current != find?.current {
            Self.applyHighlights(find, to: view)
        }
        c.shown = (text, scale, find?.query, find?.current)
    }

    /// Every match of the query behind the PDF panes' match yellow, the current hit behind the system
    /// find-highlight colour, and the current hit scrolled into view. Attributes only, so the user's
    /// selection stays where it is.
    private static func applyHighlights(_ find: (query: String, current: Int?)?, to view: NSTextView) {
        guard let storage = view.textStorage else { return }
        if let current = highlight(storage, find: find) { view.scrollRangeToVisible(current) }
    }

    /// Mark `storage`'s matches; returns the current hit's range, if there is one.
    @discardableResult
    static func highlight(_ storage: NSTextStorage, find: (query: String, current: Int?)?) -> NSRange? {
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        guard let find else { return nil }
        var current: NSRange?
        for (k, range) in highlightRanges(query: find.query, in: storage.string).enumerated() {
            if k == find.current { current = range }
            storage.addAttribute(.backgroundColor, value: k == find.current
                                 ? NSColor.findHighlightColor : NSColor.systemYellow.withAlphaComponent(0.5),
                                 range: range)
        }
        return current
    }

    /// The query's matches in `text` as NSRanges, in the order `DocumentFindScanner` counts them.
    static func highlightRanges(query: String, in text: String) -> [NSRange] {
        DocumentFindScanner.ranges(of: query, in: text).map { NSRange($0, in: text) }
    }
}

/// The extracted-text pane's text view. Edit ▸ Copy here is the viewer's verbatim copy, plain text only:
/// NSTextView's own would also put the find highlights on the pasteboard as rich text.
final class ExtractedTextView: NSTextView {
    weak var controller: ExtractedTextController?

    override func copy(_ sender: Any?) {
        if let copy = controller?.copySelection { copy() } else { super.copy(sender) }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copy(_:)), let canCopy = controller?.canCopySelection { return canCopy() }
        return super.validateMenuItem(menuItem)
    }
}
