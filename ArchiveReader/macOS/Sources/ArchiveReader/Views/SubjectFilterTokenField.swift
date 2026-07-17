import SwiftUI
import AppKit

/// The tag-**filter** field: the selected subject filters ARE the tokens, shown *inside* the field
/// (owner design, 2026-07-16). Type to autocomplete from the corpus's existing subjects; Return/comma
/// adds a filter; selecting a token + ⌫ removes it. Read-only over the corpus — it only feeds the
/// in-memory `LibraryFilter` and never touches `TagWriter`.
///
/// **Why a token field (the BUG-3 fix).** The selected filters used to render as separate chip buttons
/// *beside* an "Add tag filter…" combo box, inside a single-row filter bar that already sits near the
/// window width. Each added chip widened the bar's hard-minimum width, which tipped the whole content
/// column past the window, so the root `HStack` re-centered and visibly shifted the file table left.
/// Tokens live INSIDE this bounded, single-line, horizontally-scrolling field, which also has LOW
/// horizontal compression resistance — so it yields width rather than forcing its parent wider, and
/// adding filters adds **zero** width to the bar. The shift is fixed by construction instead of by
/// tuning a container's width (two container attempts — a capped `ScrollView` and a wrapping
/// `FlowLayout` — each traded one glitch for another; see ArchiveReader/KNOWN_ISSUES.md).
struct SubjectFilterTokenField: NSViewRepresentable {
    @Binding var subjects: Set<String>
    var suggestions: [String]
    var placeholder: String
    var focusToken: Int = 0        // bump to request keyboard focus (⌘L)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let tf = NSTokenField()
        tf.delegate = context.coordinator
        tf.tokenStyle = .rounded
        tf.bezelStyle = .roundedBezel
        tf.isBordered = true
        tf.drawsBackground = true
        tf.placeholderString = placeholder
        tf.tokenizingCharacterSet = CharacterSet(charactersIn: ",")   // comma tokenizes; Return commits
        tf.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        tf.lineBreakMode = .byTruncatingTail
        tf.usesSingleLineMode = true
        if let cell = tf.cell as? NSTokenFieldCell { cell.wraps = false; cell.isScrollable = true }
        // Compressible + non-greedy: the field yields horizontal space instead of forcing the filter bar
        // (and thus the content column) wider. This is what keeps the file table from shifting.
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.setAccessibilityIdentifier("ar.filter.tagField")
        tf.objectValue = subjects.sorted()
        return tf
    }

    func updateNSView(_ tf: NSTokenField, context: Context) {
        context.coordinator.parent = self
        tf.placeholderString = placeholder
        // Freeze while the user is editing (mirrors SubjectTokenField): a re-render must not clobber an
        // in-progress edit. When idle, re-sync from the model so an external change — a tag-cloud click,
        // "Clear", or a smart-folder scope — shows up as tokens here.
        if tf.currentEditor() == nil {
            let want = subjects.sorted()
            if ((tf.objectValue as? [String]) ?? []) != want { tf.objectValue = want }
        }
        if focusToken != context.coordinator.lastFocusToken {          // ⌘L requested focus
            context.coordinator.lastFocusToken = focusToken
            DispatchQueue.main.async { [weak tf] in tf?.window?.makeFirstResponder(tf) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: SubjectFilterTokenField
        var lastFocusToken = 0

        init(_ parent: SubjectFilterTokenField) { self.parent = parent }

        /// Autocomplete the token being typed from the corpus's existing subjects (case-insensitive
        /// prefix match; drops an already-complete match), so filters stay in the real vocabulary.
        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String,
                        indexOfToken tokenIndex: Int,
                        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            let s = substring.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { return [] }
            let matches = parent.suggestions.filter {
                $0.caseInsensitiveCompare(s) != .orderedSame &&
                $0.range(of: s, options: [.caseInsensitive, .anchored]) != nil
            }
            return Array(matches.prefix(20))
        }

        /// ADDs come through here (Return, comma, a completion pick, or blur auto-tokenizing typed text).
        /// Additions are taken ONLY from this callback — never from `controlTextDidChange` — because a
        /// half-typed substring can appear in `objectValue` before it is tokenized, and pushing that would
        /// filter on a partial word with every keystroke. Deferred to the next runloop turn so the model
        /// isn't mutated inside the delegate call.
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let added = tokens.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces) }
                              .filter { !$0.isEmpty }
            if !added.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.parent.subjects.formUnion(added) }
            }
            return tokens
        }

        /// REMOVALs (select a token + ⌫) have no dedicated delegate callback, so detect them here — but
        /// only ever *subtract*, so a partially-typed substring can never add a filter (see `shouldAdd`).
        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField else { return }
            let tokens = Set(((tf.objectValue as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
            let removed = parent.subjects.subtracting(tokens)
            if !removed.isEmpty { parent.subjects.subtract(removed) }
        }

        /// On blur, reconcile in both directions — this is where text typed but never Return'd gets
        /// auto-tokenized by `NSTokenField` and becomes a filter (WYSIWYG, matching the inline tag
        /// editor's owner-chosen behaviour: typed text sticks; a wrong filter is removable with ⌫).
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let tf = obj.object as? NSTokenField else { return }
            let tokens = Set(((tf.objectValue as? [String]) ?? [])
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
            if tokens != parent.subjects { parent.subjects = tokens }
        }
    }
}
