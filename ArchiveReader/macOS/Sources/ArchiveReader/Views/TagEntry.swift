import AppKit

/// How the Reader's tag-entry token fields treat an autocompletion (W40.fix-reader-tag-entry; owner session
/// reader-1, rows 28, 29 and 36). The list's inline tag field, the Edit Tags sheet's subject field and the tag
/// filter share it, so the three behave alike: a space keeps what was typed, Tab or → takes the suggestion.
@MainActor
enum TagEntry {
    /// Existing subjects that complete `substring`: a case-insensitive prefix match, with an exact match left out.
    ///
    /// Only leading whitespace is dropped. Trailing whitespace is part of what was typed: when it was trimmed,
    /// "Civ " still matched "Civil War", the field put the suggestion back over the space, and a space could not
    /// be typed until the rest of the suggestion was taken. Subjects are often two words, so the space stays a
    /// space and the completion ends there unless a subject really starts "Civ ".
    static func completions(for substring: String, in subjects: [String], limit: Int = 20) -> [String] {
        let s = String(substring.drop(while: { $0 == " " || $0 == "\t" }))
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Array(subjects.lazy.filter {
            $0.caseInsensitiveCompare(s) != .orderedSame &&
            $0.range(of: s, options: [.caseInsensitive, .anchored]) != nil
        }.prefix(limit))
    }

    /// The text typed after the tokens, which Return or a comma would make a tag. A token is one attachment
    /// character in the field editor's string.
    static func pendingText(in textView: NSTextView) -> String {
        textView.string.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Tab takes an inline completion. The field shows a suggestion as selected text after the caret, so taking
    /// it is moving the caret to the end of that selection, as → does. Returns false when nothing is selected or
    /// the selection holds a token, and Tab then keeps its usual meaning.
    static func acceptInlineCompletion(in textView: NSTextView) -> Bool {
        let selected = textView.selectedRange()
        guard selected.length > 0, selected.location != NSNotFound else { return false }
        let text = (textView.string as NSString).substring(with: selected)
        guard !text.contains("\u{FFFC}") else { return false }
        textView.setSelectedRange(NSRange(location: NSMaxRange(selected), length: 0))
        return true
    }
}
