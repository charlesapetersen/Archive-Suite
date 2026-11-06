import Foundation

// Tag identity (W40.fix-tags-case-insensitive; SPEC/tag-format.md §Safety rule 4): tokens that differ
// only in case are ONE tag. Every app groups, counts, filters, dedupes and looks tags up by `tagKey`,
// while each file keeps the spelling it has: the key is never written. `isSameTag` / `shouldRemoveTag`
// (TagWrite.swift) are the write-side forms of the same rule.

/// A tag's identity key. Full case folding with no locale, so it is the same on every Mac ("Straße" and
/// "STRASSE" are one tag); accents are not folded ("Cafe" and "Café" stay two). Compare keys with `==`,
/// which already treats canonically equivalent spellings (composed and decomposed é) as equal.
///
/// A token shaped like a facet the parser reads by its exact spelling keeps that spelling as its key
/// (`keepsExactCase`): `Q2` is a rating but `q2` is a fiscal-quarter subject, and `Red` is the box
/// marker's colour token while `red` may be a subject, so folding them together would let a rating or
/// colour edit add, skip or remove the other token (the Tier-2 review of this change). Such a key is
/// marked so it can never equal a folded one: the decade `1970s` and a subject `1970S`, folded to
/// "1970s", stay two tags.
public func tagKey(_ s: String) -> String {
    TagKeyMemo.shared.key(s)
}

/// Whether `s` keeps its exact case as its tag identity: a rating (`Q1`–`Q3`, `P7`–`P10`), a date facet
/// (year, decade, `MM Month`, `Day N`, `Date Uncertain`, `Sent With …`), or a marker colour name.
/// `Read`/`Unread` fold like any subject: the parser and the writer already match them in any case.
public func keepsExactCase(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    return DocumentTags.isRatingToken(t) || DocumentTags.isDateFacetLike(t)
        || [ArchiveColor.box, .folder].contains { $0.tokenName.caseInsensitiveCompare(t) == .orderedSame }
}

/// `tagKey` is asked for every subject of every row when a library of ~10^5 files loads, but a library
/// has ~10^4 spellings: each is worked out once. Bounded; emptied when full.
private final class TagKeyMemo: @unchecked Sendable {
    static let shared = TagKeyMemo()
    private static let limit = 200_000
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    func key(_ s: String) -> String {
        lock.lock()
        if let k = keys[s] { lock.unlock(); return k }
        lock.unlock()
        let k = keepsExactCase(s) ? "\u{0}" + s : s.folding(options: .caseInsensitive, locale: nil)
        lock.lock()
        if keys.count >= Self.limit { keys.removeAll(keepingCapacity: true) }
        keys[s] = k
        lock.unlock()
        return k
    }
}

/// Counts tags by identity across `tagLists` (one list per file, each tag counted once per file), shown
/// in the spelling most files use; a tie goes to the spelling that sorts first, so the result does not
/// depend on file order. `include` filters tokens before counting. Unsorted.
public func tagCounts<S: Sequence>(_ tagLists: S, include: (String) -> Bool = { _ in true })
    -> [(tag: String, count: Int)] where S.Element == [String] {
    var files: [String: Int] = [:]
    var spellings: [String: [String: Int]] = [:]
    for tags in tagLists {
        var seen = Set<String>()
        var spelt = Set<String>()
        for t in tags where include(t) {
            let key = tagKey(t)
            if seen.insert(key).inserted { files[key, default: 0] += 1 }
            if spelt.insert(t).inserted { spellings[key, default: [:]][t, default: 0] += 1 }
        }
    }
    return files.map { key, count in
        let shown = spellings[key, default: [:]].max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key ?? key
        return (tag: shown, count: count)
    }
}
