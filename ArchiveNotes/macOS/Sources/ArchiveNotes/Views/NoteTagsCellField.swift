import AppKit
import ArchiveCore

/// The list's Tags cell while its tags are edited in place (W40.notes-detail-layout; owner session notes-1 row 7: the
/// date and the tags could not be edited in the list, as the title can). A token field laid over the cell's label: the
/// note's tags as tokens, which can be deleted, and new ones typed with the suite's tag autocompletion (`TagEntry`, as
/// in the tag bar's `SubjectEntryField`). Return or leaving the field saves, Escape puts the tags back untouched. The
/// owner removes the field on `onEnd`, on a later turn, since it ends inside the field's own key handling. The
/// commit captures the item it began on, never a row, so a re-sort or a selection change cannot move it.
@MainActor
final class NoteTagsCellField: NSTokenField, NSTokenFieldDelegate {
    private let original: [String]
    private let suggestions: () -> [String]
    private let onCommit: ([String]) -> Void
    private let onEnd: () -> Void
    private var cancelled = false
    private var finished = false

    init(tags: [String], suggestions: @escaping () -> [String], onCommit: @escaping ([String]) -> Void,
         onEnd: @escaping () -> Void) {
        original = tags
        self.suggestions = suggestions
        self.onCommit = onCommit
        self.onEnd = onEnd
        super.init(frame: .zero)
        tokenStyle = .rounded
        tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        font = .systemFont(ofSize: NSFont.systemFontSize)
        usesSingleLineMode = true
        if let cell = cell as? NSTokenFieldCell { cell.wraps = false; cell.isScrollable = true }
        objectValue = tags
        delegate = self
        setAccessibilityLabel("Tags")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int,
                    indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let taken = Set((tokens ?? []).map { $0.lowercased() })
        let subjects = suggestions().filter { !taken.contains($0.lowercased()) }
        let found = TagEntry.completions(for: substring, in: subjects)
        selectedIndex?.pointee = TagEntry.filledInIndex(for: substring, in: found, among: subjects, anyCase: true)
        return found
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            finish(pending: nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finish(pending: TagEntry.pendingText(in: textView))
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) { finish(pending: nil) }

    /// The tokens in the field, without the text still being typed; nil when the field does not hold a token list,
    /// which saves nothing rather than reading as "every tag removed".
    private var tokens: [String]? {
        guard let values = objectValue as? [Any] else { return nil }
        return values.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Saves the tags shown (and `pending`, text typed but not yet a token) unless cancelled, and asks the owner to
    /// take the field away. Return and Escape hand the keyboard back to the list, as the title's field does; a click
    /// elsewhere leaves it where it went. Runs once (handing the keyboard back ends the editing again).
    private func finish(pending: String?) {
        guard !finished else { return }
        finished = true
        if !cancelled, var edited = tokens {
            if let pending, !pending.isEmpty, !edited.contains(pending) { edited.append(pending) }
            if edited != original { onCommit(edited) }
        }
        if cancelled || pending != nil, let table = enclosingTable { window?.makeFirstResponder(table) }
        onEnd()
    }

    private var enclosingTable: NSTableView? {
        var view = superview
        while let candidate = view, !(candidate is NSTableView) { view = candidate.superview }
        return view as? NSTableView
    }
}
