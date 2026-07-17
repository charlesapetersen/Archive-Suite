import Foundation
import ArchiveCore

// ============================================================================================
//  TagWriter — Reader's DELTA ADAPTER over ArchiveCore.CoordinatedTagWriter.
//
//  This is the Reader's write surface. Every Reader tag mutation — Read/Unread triage,
//  subject/date/priority edits, group edits — goes through here. It translates Reader-specific
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

    /// Apply the same delta to a group of files. Each file is an INDEPENDENT, idempotent unit — never
    /// all-or-nothing. Returns a per-file Result so the caller can surface partial failures.
    /// (No §6 identity check on this path — group edits that want it call the single-file `apply`
    /// with a per-file `expecting:` once callers capture identity at selection.)
    static func apply(_ delta: TagDelta, to urls: [URL]) -> [(url: URL, result: Result<TagWriteResult, Error>)] {
        urls.map { url in (url, Result { try apply(delta, to: url) }) }
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
}
