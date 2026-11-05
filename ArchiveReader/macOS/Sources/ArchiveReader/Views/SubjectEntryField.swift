import SwiftUI
import AppKit

/// The Edit Tags sheet's add-a-subject field (W40.fix-reader-tag-entry, owner session reader-1 row 28): it
/// autocompletes from the library's subjects as the list's tag field does, with the same keys (`TagEntry`).
/// Return or a comma adds what is typed and the field keeps the keyboard for the next one; Tab adds the suggestion
/// and moves on. The field keeps no tokens: the sheet's chips above it show the tags, so each added subject leaves
/// the field empty.
///
/// `draft` is the text typed so far, for the sheet's case warning and its Add button. Setting it to "" from
/// outside (the Add button, once it has added the draft) empties the field.
struct SubjectEntryField: NSViewRepresentable {
    @Binding var draft: String
    var placeholder: String
    /// The subjects to suggest, asked for when a completion is wanted rather than on every render.
    var suggestions: () -> [String]
    var onAdd: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
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
        tf.setAccessibilityIdentifier("ar.tagEditor.addSubject")
        return tf
    }

    func updateNSView(_ tf: NSTokenField, context: Context) {
        context.coordinator.parent = self
        if draft.isEmpty { context.coordinator.clear(tf) }
    }

    @MainActor final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: SubjectEntryField

        init(_ parent: SubjectEntryField) { self.parent = parent }

        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let found = TagEntry.completions(for: substring, in: parent.suggestions())
            selectedIndex?.pointee = TagEntry.filledInIndex(for: substring, in: found)
            return found
        }

        /// A comma, or Tab on a suggestion, makes a token; each one is added to the files on the next turn (so the
        /// model is not changed inside the delegate call), and the field is emptied.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            DispatchQueue.main.async { [weak self, weak tokenField] in
                if let self, let tokenField { self.harvest(tokenField) }
            }
            return tokens
        }

        /// Leaving the field adds what is in it, tokens and text alike: typed text sticks, as in the list's field.
        /// Tab on a suggestion turns it into a token without calling `shouldAdd` and moves on, so it arrives here.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField else { return }
            harvest(tf)
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField, let editor = tf.currentEditor() as? NSTextView else { return }
            let typed = TagEntry.pendingText(in: editor, includingSuggestion: false)
            if parent.draft != typed { parent.draft = typed }
        }

        /// Return adds the subject in the field, a suggestion showing in it included, as Return does in the list's
        /// field; the field is emptied and keeps the keyboard.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  let tf = control as? NSTokenField else { return false }
            let subject = TagEntry.pendingText(in: textView)
            guard !subject.isEmpty else { return false }
            parent.draft = ""
            clear(tf)
            DispatchQueue.main.async { [weak self] in self?.parent.onAdd(subject) }
            return true
        }

        /// Adds every subject the field holds and empties it. A subject the files already have is not written
        /// again (`TagWriter` journals and writes nothing for a no-op), so the field tokenizing text the Add or
        /// Done button has just added changes nothing.
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
        func clear(_ tf: NSTokenField) {
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
