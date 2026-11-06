import SwiftUI
import AppKit

/// An add-a-tag field that autocompletes from existing tags, with the keys `TagEntry` gives every tag field in the
/// suite. The Reader's Edit Info sheet (W40.fix-reader-tag-entry, owner session reader-1 row 28) and Notes' tag
/// field (W40.fix-notes-tag-entry, owner session notes-1 row 26: "Pressing return should add them — we should not
/// use an 'Add' button") use this one field.
/// Return or a comma adds what is typed and the field keeps the keyboard for the next one; Tab adds the suggestion
/// and moves on. The field keeps no tokens: the caller shows the tags elsewhere, so each added tag leaves the field
/// empty.
///
/// `draft` is the text typed so far, for a caller's case warning or Add button. Setting it to "" from outside (an
/// Add button, once it has added the draft) empties the field.
public struct SubjectEntryField: NSViewRepresentable {
    @Binding var draft: String
    var placeholder: String
    var identifier: String
    /// Whether a suggestion is filled in after the caret whatever its case. The Reader keeps the typed case, so it
    /// fills in only a suggestion that starts with exactly what was typed (`TagEntry.filledInIndex`), and warns of
    /// a case variant. Notes has no such warning and fills in the first, so a tag is taken in the spelling the
    /// other notes have; a variant can still be typed in full, as an exact match is never suggested.
    var fillsInAnyCase: Bool
    /// The tags to suggest, asked for when a completion is wanted rather than on every render.
    var suggestions: () -> [String]
    var onAdd: (String) -> Void

    public init(draft: Binding<String>, placeholder: String, identifier: String, fillsInAnyCase: Bool = false,
                suggestions: @escaping () -> [String], onAdd: @escaping (String) -> Void) {
        _draft = draft
        self.placeholder = placeholder
        self.identifier = identifier
        self.fillsInAnyCase = fillsInAnyCase
        self.suggestions = suggestions
        self.onAdd = onAdd
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> NSTokenField {
        let tf = NSTokenField()
        tf.delegate = context.coordinator
        tf.tokenStyle = .rounded
        tf.bezelStyle = .roundedBezel
        tf.isBordered = true
        tf.drawsBackground = true
        tf.placeholderString = placeholder
        tf.tokenizingCharacterSet = CharacterSet(charactersIn: ",")
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        if let cell = tf.cell as? NSTokenFieldCell { cell.wraps = false; cell.isScrollable = true }
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.setAccessibilityLabel(placeholder)
        tf.setAccessibilityIdentifier(identifier)
        return tf
    }

    public func updateNSView(_ tf: NSTokenField, context: Context) {
        context.coordinator.parent = self
        if draft.isEmpty { context.coordinator.clear(tf) }
    }

    @MainActor public final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: SubjectEntryField

        init(_ parent: SubjectEntryField) { self.parent = parent }

        public func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let found = TagEntry.completions(for: substring, in: parent.suggestions())
            selectedIndex?.pointee = parent.fillsInAnyCase ? (found.isEmpty ? -1 : 0)
                                                           : TagEntry.filledInIndex(for: substring, in: found)
            return found
        }

        /// A comma, or Tab on a suggestion, makes a token; each one is added to the files on the next turn (so the
        /// model is not changed inside the delegate call), and the field is emptied.
        public func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            DispatchQueue.main.async { [weak self, weak tokenField] in
                if let self, let tokenField { self.harvest(tokenField) }
            }
            return tokens
        }

        /// Leaving the field adds what is in it, tokens and text alike: typed text sticks, as in the list's field.
        /// Tab on a suggestion turns it into a token without calling `shouldAdd` and moves on, so it arrives here.
        public func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField else { return }
            harvest(tf)
        }

        public func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField, let editor = tf.currentEditor() as? NSTextView else { return }
            let typed = TagEntry.pendingText(in: editor, includingSuggestion: false)
            if parent.draft != typed { parent.draft = typed }
        }

        /// Return adds the subject in the field, a suggestion showing in it included, as Return does in the list's
        /// field; the field is emptied and keeps the keyboard.
        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let tf = control as? NSTokenField else { return false }
            let subject = TagEntry.pendingText(in: textView)
            guard !subject.isEmpty else { return false }
            parent.draft = ""
            clear(tf)
            DispatchQueue.main.async { [weak self] in self?.parent.onAdd(subject) }
            return true
        }

        /// Adds every subject the field holds and empties it. The caller's add must be a no-op for a tag already
        /// there (the Reader's `TagWriter` journals and writes nothing; Notes' add is a set union), so the field
        /// tokenizing text an Add or Done button has just added changes nothing.
        private func harvest(_ tf: NSTokenField) {
            let subjects = ((tf.objectValue as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !subjects.isEmpty else { return }
            subjects.forEach(parent.onAdd)
            if !parent.draft.isEmpty { parent.draft = "" }
            clear(tf)
        }

        /// Empties the field, keeping the keyboard in it. While it is being edited the text is removed as an edit
        /// of the field editor's text, so the editor's undo history stays consistent with its contents.
        public func clear(_ tf: NSTokenField) {
            if let editor = tf.currentEditor() as? NSTextView {
                let all = NSRange(location: 0, length: (editor.string as NSString).length)
                guard all.length > 0, editor.shouldChangeText(in: all, replacementString: "") else { return }
                editor.replaceCharacters(in: all, with: "")
                editor.didChangeText()
            } else if !((tf.objectValue as? [Any])?.isEmpty ?? tf.stringValue.isEmpty) {
                tf.objectValue = []
            }
        }
    }
}
