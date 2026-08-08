import SwiftUI
import AppKit

/// Inline subject-tag editor for a navigation-list cell: an `NSTokenField` whose tokens ARE the file's
/// subject tags (removable chips), with inline typing to add and native completion from the corpus's
/// existing subjects. No popover — edit happens right in the row. Every commit is diffed against the
/// tokens the user STARTED from and applied as ONE delta through the audited `TagWriter` (see
/// `NavigationModel.commitSubjectEdit`); this view never mutates a file directly.
///
/// Safety-critical details (see the adversarial review that drove them):
/// - **Edit-start base snapshot.** The diff base is captured when editing begins (`editBase`), NOT the
///   live `subjects`. During an active edit the row can re-render (a repeat emission from a re-walk /
///   group edit / undo to the same file republishes `model.displayed`); diffing against the *edit-start*
///   base means the
///   delta names only what the USER changed, so a concurrently-added third-party tag is never dropped.
/// - **Frozen during edit.** While this field is first responder, `updateNSView` re-syncs neither the
///   displayed tokens nor the commit closure — the edit isn't clobbered and the commit target stays put.
/// - **WYSIWYG commit on blur (owner decision 2026-07-08).** Whatever is in the field when editing ends —
///   including a typed-but-not-Return'd word that `NSTokenField` auto-tokenizes on blur — is committed as a
///   subject. (Earlier this dropped a half-typed word; the owner prefers typed text to *stick*. Adds still
///   route through the audited `TagWriter` delta, so existing tags are never lost — only the newly added
///   subject may be an incomplete word, which the user can remove with ⌫/×.)
///
/// Single-line + font-tracked so it matches the table's implicit row height (`ar.listFontSize`, 10–20pt);
/// overflowing tokens scroll horizontally.
struct SubjectTokenField: NSViewRepresentable {
    var subjects: [String]            // the file's current subject tokens (display + re-sync source)
    var suggestions: [String]         // model.allSubjects — the autocomplete source
    var fontSize: Double              // tracks ar.listFontSize so the field matches the row height
    var commit: (_ base: [String], _ edited: [String]) -> Void   // (edit-start tokens, final tokens)

    func makeCoordinator() -> Coordinator { Coordinator(commit: commit, suggestions: suggestions) }

    func makeNSView(context: Context) -> NSTokenField {
        let tf = NSTokenField()
        tf.delegate = context.coordinator
        tf.tokenStyle = .rounded
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.placeholderString = "Add tags…"                              // hint + discoverability when empty
        tf.tokenizingCharacterSet = CharacterSet(charactersIn: ",")     // comma tokenizes; Return commits
        tf.font = .systemFont(ofSize: fontSize)
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        if let cell = tf.cell as? NSTokenFieldCell { cell.wraps = false; cell.isScrollable = true }
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.objectValue = subjects
        return tf
    }

    func updateNSView(_ tf: NSTokenField, context: Context) {
        context.coordinator.suggestions = suggestions
        if tf.font?.pointSize != CGFloat(fontSize) { tf.font = .systemFont(ofSize: fontSize) }
        // While the user is editing THIS field, freeze BOTH the commit closure (which carries the target
        // file) and the visible tokens. A concurrent re-render must not repoint the commit or clobber the
        // in-progress edit; the edit-start base snapshot then guarantees the diff reflects only the user's
        // changes. currentEditor() is non-nil exactly while this field is being edited.
        if tf.currentEditor() == nil {
            context.coordinator.commit = commit
            let current = (tf.objectValue as? [String]) ?? []
            if current != subjects { tf.objectValue = subjects }
        }
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var commit: (_ base: [String], _ edited: [String]) -> Void
        var suggestions: [String]
        private var editBase: [String]?      // tokens shown when this edit began — the diff base

        init(commit: @escaping (_ base: [String], _ edited: [String]) -> Void, suggestions: [String]) {
            self.commit = commit
            self.suggestions = suggestions
        }

        /// Autocomplete the token being typed from the corpus's existing subjects (case-insensitive
        /// prefix match; drops an already-complete match). Keeps the controlled vocabulary consistent.
        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let s = substring.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return [] }
            let matches = suggestions.filter {
                $0.caseInsensitiveCompare(s) != .orderedSame &&
                $0.range(of: s, options: [.caseInsensitive, .anchored]) != nil
            }
            return Array(matches.prefix(20))
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField else { return }
            editBase = (tf.objectValue as? [String]) ?? []
        }

        /// Commit on end-editing — **WYSIWYG** (owner decision 2026-07-08). Whatever tokens are in the field
        /// when editing ends persist, INCLUDING a typed-but-not-Return'd word that `NSTokenField`
        /// auto-tokenizes on blur (clicking another row / switching window). The model diffs `edited` against
        /// the edit-start `base`, so a repeated / no-change commit is a no-op, and every add routes through
        /// the audited `TagWriter` delta — so existing tags are never lost; only a newly typed (possibly
        /// incomplete) subject is added, which the user can remove.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField, let base = editBase else { editBase = nil; return }
            let edited = (tf.objectValue as? [String]) ?? []
            editBase = nil
            commit(base, edited)
        }
    }
}
