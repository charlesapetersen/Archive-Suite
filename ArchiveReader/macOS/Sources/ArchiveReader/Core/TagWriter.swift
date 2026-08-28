import Foundation
import ArchiveCore

// ============================================================================================
//  TagWriter — Reader's DELTA ADAPTER over ArchiveCore.CoordinatedTagWriter.
//
//  This is the Reader's write surface. Every Reader tag mutation — Read/Unread triage,
//  subject/date/quality edits, group edits — goes through here. It translates Reader-specific
//  delta/color semantics into a transform closure and hands it to the shared primitive.
//  See CLAUDE.md → Safety Protocol.
// ============================================================================================

enum TagWriter {

    // MARK: Public API

    /// Apply a delta to one file's tags, safely. Returns the result (with an inverse for undo), or
    /// throws having made no lasting unintended change. An empty or no-effect delta writes nothing.
    ///
    /// `expecting`: pass the `FileIdentity` captured when the row was discovered/selected to have the
    /// write target's identity re-verified inside coordination (Safety §6); a file moved/replaced
    /// under the same path aborts with `.identityMismatch`. `nil` (default) skips the check.
    static func apply(_ delta: TagDelta, to url: URL, expecting identity: FileIdentity? = nil) throws -> TagWriteResult {
        try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            var removals = delta.remove
            var additions = delta.add
            var targetLabel = label

            switch delta.color {
            case .set(let c):
                additions.append(c.tokenName)
                if let current = ArchiveColor(labelNumber: label ?? 0), current != c {
                    removals.append(current.tokenName)
                }
                targetLabel = c.labelNumber
            case .clear:
                if let current = ArchiveColor(labelNumber: label ?? 0) {
                    removals.append(current.tokenName)
                }
                targetLabel = 0
            case .restoreLabel(let lbl):
                targetLabel = lbl
            case nil:
                break
            }

            // §5 lossless compute — remove matched tokens, keep the rest verbatim & in place.
            var newTags = current.filter { token in
                !removals.contains { shouldRemoveTag(token, matching: $0) }
            }
            // Append additions not already present (case-insensitive for Read/Unread).
            for add in additions where !newTags.contains(where: { isSameTag($0, add) }) {
                newTags.append(add)
            }

            if newTags == current && normalizedLabel(targetLabel) == normalizedLabel(label) { return nil }
            return (newTags, targetLabel)
        }
    }

    /// Undo/restore path: apply an OCCURRENCE-AWARE (multiset) inverse to one file's tags. Unlike the
    /// set-based `apply(_:to:)` above — whose add step appends a token only when ABSENT (see line ~52), so
    /// it can never re-introduce a duplicate even given a correct inverse — this restores each token's exact
    /// OCCURRENCE COUNT. It runs as a **bounded reconcile step**: the transform receives the FRESH on-disk
    /// state (read inside `CoordinatedTagWriter`'s coordination block, §2/§3) and reconciles the delta
    /// against it by multiset count. Safety §9 holds: only the tokens named in the delta are touched, each by
    /// no more than its listed multiplicity, so an unrelated concurrent edit — and any extra copy a
    /// concurrent edit added of a *named* token — survives. Occurrence-only (count, not order; macOS reorders
    /// tags on write anyway, and the SPEC compares tag arrays as a multiset).
    ///
    /// The `TagOccurrenceDelta` consumed here is only ever an undo inverse (`tagOccurrenceInverse`), whose
    /// `color` is `.restoreLabel(_:)` or nil and whose color-TOKEN changes already ride in the add/remove
    /// multisets — so color here only restores the label number (mirroring `.restoreLabel` in `apply`); the
    /// `.set`/`.clear` arms are handled defensively but never arise on this path. `expecting:` re-verifies §6
    /// identity exactly like `apply`. Read/Unread tokens are matched EXACTLY (not case-folded): the inverse
    /// carries the exact token read from disk, so exact match both restores correctly and avoids disturbing a
    /// token a concurrent edit re-cased.
    static func applyOccurrence(_ delta: TagOccurrenceDelta, to url: URL,
                                expecting identity: FileIdentity? = nil) throws -> TagWriteResult {
        try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            var targetLabel = label
            switch delta.color {
            case .restoreLabel(let lbl): targetLabel = lbl
            case .set(let c):            targetLabel = c.labelNumber   // never produced by an inverse; defensive
            case .clear:                 targetLabel = 0               // "
            case nil:                    break
            }

            // §9 occurrence-precise reconcile against the FRESH read: strip EXACTLY the listed number of
            // occurrences of each removed token (a copy a concurrent edit added survives), keep every other
            // token verbatim & in place, then append the listed occurrences of each added token — this last
            // step is what re-introduces a duplicate the set path (line ~52) refuses to.
            var removalBudget: [String: Int] = [:]
            for t in delta.remove { removalBudget[t, default: 0] += 1 }
            var newTags: [String] = []
            newTags.reserveCapacity(current.count + delta.add.count)
            for token in current {
                if let n = removalBudget[token], n > 0 { removalBudget[token] = n - 1 }  // cancel one occurrence
                else { newTags.append(token) }                                           // keep verbatim
            }
            newTags.append(contentsOf: delta.add)

            if newTags == current && normalizedLabel(targetLabel) == normalizedLabel(label) { return nil }
            return (newTags, targetLabel)
        }
    }

    /// Apply the same delta to a group of files. Each file is an INDEPENDENT, idempotent unit — never
    /// all-or-nothing. Returns a per-file Result so the caller can surface partial failures.
    /// (No §6 identity check on this path — group edits that want it use the `to items:` overload below,
    /// passing a per-file `FileIdentity` captured at selection/edit.)
    static func apply(_ delta: TagDelta, to urls: [URL]) -> [(url: URL, result: Result<TagWriteResult, Error>)] {
        urls.map { url in (url, Result { try apply(delta, to: url) }) }
    }

    /// Group apply WITH per-file §6 identity re-verification — the identity-carrying sibling of the
    /// `to urls:` overload above, for the group/batch call sites (e.g. corpus-wide tag rename). Each
    /// `(url, identity)` pair is an INDEPENDENT, idempotent unit (never all-or-nothing): the file is
    /// tagged only if the resolved write target still matches the captured `identity`; a `nil` identity
    /// skips the check for that file, exactly like the single-file default. An identity mismatch surfaces
    /// as `.failure(TagWriteError.identityMismatch)` for that one file while the rest still apply. The
    /// returned array is 1:1 and in the same order as `items`.
    static func apply(_ delta: TagDelta,
                      to items: [(url: URL, identity: FileIdentity?)]
    ) -> [(url: URL, result: Result<TagWriteResult, Error>)] {
        items.map { item in (item.url, Result { try apply(delta, to: item.url, expecting: item.identity) }) }
    }

    /// Fast-path triage: set Read/Unread by swapping the existing token.
    /// By default does NOT add a read-state token to a file that has none (protects box/folder
    /// markers, Safety §10); pass `addIfMissing: true` for an explicit "mark Read" on such files.
    static func setReadState(_ target: ReadState, on url: URL, addIfMissing: Bool = false,
                             expecting identity: FileIdentity? = nil) throws -> TagWriteResult {
        try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            let hasReadState = current.contains { isReadStateWord($0) }
            guard hasReadState || addIfMissing else { return nil }
            let alreadyTarget = current.contains { isSameTag($0, target.rawValue) }
            let hasOpposite = current.contains { isReadStateWord($0) && !isSameTag($0, target.rawValue) }
            if alreadyTarget && !hasOpposite { return nil }
            var newTags = current.filter { !isReadStateWord($0) }
            newTags.append(target.rawValue)
            if newTags == current { return nil }
            return (newTags, label)
        }
    }

    /// Conditional corpus-wide rename. The selection that nominated `url` may have come from a
    /// persisted cache, so it is not authority that `old` is still present. Re-check inside the same
    /// coordinated fresh-read transform that writes; if the token disappeared meanwhile, return a
    /// verified no-op instead of unconditionally adding `new` to the wrong selection set.
    static func renameToken(from old: String, to new: String, on url: URL,
                            expecting identity: FileIdentity? = nil) throws -> TagWriteResult {
        try CoordinatedTagWriter.write(url, expectedIdentity: identity) { current, label in
            guard current.contains(where: { shouldRemoveTag($0, matching: old) }) else { return nil }
            var renamed = current.filter { !shouldRemoveTag($0, matching: old) }
            if !renamed.contains(where: { isSameTag($0, new) }) { renamed.append(new) }
            if renamed == current { return nil }
            return (renamed, label)
        }
    }
}
