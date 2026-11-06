import AppKit

/// How the suite's tag-entry token fields treat an autocompletion (W40.fix-reader-tag-entry; owner session
/// reader-1, rows 28, 29 and 36). The Reader's inline list tag field, its Edit Info subject field and its tag
/// filter share it, and so does Notes' tag field through `SubjectEntryField` (W40.fix-notes-tag-entry), so they
/// behave alike: a space keeps what was typed, and Tab or → takes the suggestion.
/// The Reader's list field and sheet fill a suggestion in only where it keeps the typed case (`filledInIndex`); the
/// filter fills in the first, as a filter names a subject that exists, and so does Notes (`SubjectEntryField`'s
/// `fillsInAnyCase`).
/// Tab and → need nothing here: with a suggestion showing, the token field itself turns it into a token on Tab
/// (and moves on to the next control) and → moves the caret past it.
@MainActor
public enum TagEntry {
    /// Existing subjects that complete `substring`: a case-insensitive prefix match, with an exact match left out.
    ///
    /// Only leading whitespace is dropped. Trailing whitespace is part of what was typed: when it was trimmed,
    /// "Civ " still matched "Civil War", the field put the suggestion back over the space, and a space could not
    /// be typed until the rest of the suggestion was taken. Subjects are often two words, so the space stays a
    /// space and the completion ends there unless a subject really starts "Civ ".
    public static func completions(for substring: String, in subjects: [String], limit: Int = 20) -> [String] {
        let s = typedPrefix(substring)
        guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Array(subjects.lazy.filter {
            $0.caseInsensitiveCompare(s) != .orderedSame &&
            $0.range(of: s, options: [.caseInsensitive, .anchored]) != nil
        }.prefix(limit))
    }

    /// The completion the field fills in after the caret, or -1 for none (the list still shows). Only one that
    /// starts with exactly what was typed is filled in: the field writes the filled-in completion over the typed
    /// text, so a case-insensitive one turned "w40d8 m" into "W40d8 M" and a case variant could not be typed (the
    /// sheet's case warning, R-27, never showed). Case is kept as typed; Tab or → takes a filled-in completion, and
    /// ↓ picks one from the list.
    public static func filledInIndex(for substring: String, in completions: [String]) -> Int {
        let s = typedPrefix(substring)
        return completions.firstIndex { $0.hasPrefix(s) } ?? -1
    }

    /// The completion `SubjectEntryField` fills in, or -1 for none. Nothing is filled in when what was typed is
    /// already one of `subjects` (any case): an exact match is never a completion, so "Intel" typed in full showed
    /// "Intelligence" after the caret, and Return added the longer tag (W40.fix-notes-tag-entry review). With
    /// `anyCase` the first completion is filled in whatever its case; otherwise as `filledInIndex(for:in:)`.
    public static func filledInIndex(for substring: String, in completions: [String], among subjects: [String],
                                     anyCase: Bool) -> Int {
        guard !completions.isEmpty else { return -1 }
        let s = typedPrefix(substring)
        if subjects.contains(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) { return -1 }
        return anyCase ? 0 : filledInIndex(for: substring, in: completions)
    }

    private static func typedPrefix(_ substring: String) -> String {
        String(substring.drop(while: { $0 == " " || $0 == "\t" }))
    }

    /// The text after the tokens, which Return or a comma would make a tag. A token is one attachment character
    /// in the field editor's string. Without `includingSuggestion`, a selected inline completion is left out:
    /// what the person typed, not what the field suggests.
    public static func pendingText(in textView: NSTextView, includingSuggestion: Bool = true) -> String {
        var text = textView.string as NSString
        let selected = textView.selectedRange()
        if !includingSuggestion, selected.location != NSNotFound, selected.length > 0, NSMaxRange(selected) <= text.length {
            text = text.replacingCharacters(in: selected, with: "") as NSString
        }
        return (text as String).replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespaces)
    }
}
