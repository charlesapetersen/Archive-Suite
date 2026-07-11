import Foundation

// ============================================================================================
//  CoordinatedTagWriter — THE SINGLE AUDITED WRITE CHOKE-POINT.
//
//  This is the coordinated tag-write primitive shared by all Archive Suite apps. Every tag
//  mutation — Reader's delta-apply, Processor's fresh-write, Notes' tag projection — funnels
//  through `CoordinatedTagWriter.write`. It edits ONLY Finder-tag metadata (the tag-name array
//  + optionally the color label). It NEVER touches file bytes.
//
//  Guarantees (per write()):
//   §1 coordinated, metadata-only write (never .forReplacing).
//   §2 fresh read INSIDE the coordinated block (no TOCTOU).
//   §3 trustworthy-read guard — a read failure ABORTS; it is never coerced into "no tags".
//   §5 lossless compute: the transform receives the fresh state and returns the intended state.
//   §7 label written only when the transform changes it; drift otherwise restored.
//   §8 verify by re-read — multiset equality (order-independent) + label check.
//   §9 inverse delta derived from the actual before/after diff.
//  UI-free. Lives in ArchiveCore so Reader, Processor, and Notes share one audited path.
// ============================================================================================

/// A precise, reversible edit to a file's Finder tags — the only shape of mutation the apps perform.
public struct TagDelta: Sendable, Equatable {
    /// Tokens to add (skipped if already present). Order preserved; appended after existing tokens.
    public var add: [String]
    /// Tokens to remove (exact whole-string match; Read/Unread also match case-insensitively).
    public var remove: [String]
    /// Optional Finder color-label change. Keeps the color *token* and the label number consistent.
    public var color: ColorChange?

    public enum ColorChange: Sendable, Equatable {
        case set(ArchiveColor)   // box = Red(6) / folder = Purple(3)
        case clear               // label 0, and drop the color token matching the current label
        case restoreLabel(Int?)  // undo only: set the label verbatim WITHOUT touching the tag array
                                 // (the delta's add/remove already carries the exact token changes)
    }

    public init(add: [String] = [], remove: [String] = [], color: ColorChange? = nil) {
        self.add = add
        self.remove = remove
        self.color = color
    }

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty && color == nil }
}

/// The outcome of a successful write, including the inverse delta needed to undo it safely.
public struct TagWriteResult: Sendable, Equatable {
    public let url: URL
    public let before: [String]
    public let after: [String]
    public let beforeLabel: Int?
    public let afterLabel: Int?
    /// Applying this delta through the write primitive undoes this edit while preserving any concurrent
    /// third-party tag changes (it re-reads and reconciles rather than restoring a stale array).
    public let inverse: TagDelta

    public init(url: URL, before: [String], after: [String],
                beforeLabel: Int?, afterLabel: Int?, inverse: TagDelta) {
        self.url = url; self.before = before; self.after = after
        self.beforeLabel = beforeLabel; self.afterLabel = afterLabel; self.inverse = inverse
    }

    /// True when nothing actually changed (idempotent no-op).
    public var isNoOp: Bool { before.sorted() == after.sorted() && normalizedLabel(beforeLabel) == normalizedLabel(afterLabel) }
}

public enum TagWriteError: Error, Sendable, Equatable {
    case unreadable(String)          // current tags could not be read — refused (Safety §3)
    case verificationFailed(String)  // post-write re-read did not match the intended result
    case coordinationFailed(String)  // NSFileCoordinator could not obtain access
}

/// nil and 0 both mean "no color label"; normalize so they compare equal.
/// Public so app-level adapters (Reader TagWriter, Processor MacOSTagger) can use it
/// in their transform closures without duplicating the mapping.
public func normalizedLabel(_ label: Int?) -> Int { label ?? 0 }

public enum CoordinatedTagWriter {

    /// The one place that writes tags. `transform` receives the FRESHLY-READ current state (inside the
    /// coordination block) and returns the intended new state, or nil for a no-op. Everything else —
    /// the trustworthy-read guard, the write, verification, drift restore, and inverse derivation —
    /// is enforced here so no caller can bypass it.
    public static func write(
        _ url: URL,
        transform: ([String], Int?) -> ([String], Int?)?
    ) throws -> TagWriteResult {
        let box = ResultBox()
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: &coordError) { writeURL in
            do {
                // §2/§3 fresh read inside coordination; a read FAILURE aborts (never treated as empty).
                let before: [String]
                let beforeLabel: Int?
                do {
                    let rv = try writeURL.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
                    before = rv.tagNames ?? []
                    beforeLabel = rv.labelNumber
                } catch {
                    throw TagWriteError.unreadable(error.localizedDescription)
                }

                guard let (intendedTags, intendedLabel) = transform(before, beforeLabel) else {
                    box.result = TagWriteResult(url: url, before: before, after: before,
                                                beforeLabel: beforeLabel, afterLabel: beforeLabel,
                                                inverse: TagDelta())
                    return
                }

                // Write the tag array. Write the label ONLY when we intend to change it (§7).
                try (writeURL as NSURL).setResourceValue(intendedTags, forKey: .tagNamesKey)
                if normalizedLabel(intendedLabel) != normalizedLabel(beforeLabel) {
                    try (writeURL as NSURL).setResourceValue(intendedLabel ?? 0, forKey: .labelNumberKey)
                }

                // §8 verify by re-read.
                var (after, afterLabel) = try readPair(writeURL)

                // §7 label-drift defense: if we did NOT intend a color change but the label drifted
                // (e.g. from rewriting the tag array), restore the original label.
                if normalizedLabel(intendedLabel) == normalizedLabel(beforeLabel), normalizedLabel(afterLabel) != normalizedLabel(beforeLabel) {
                    try (writeURL as NSURL).setResourceValue(beforeLabel ?? 0, forKey: .labelNumberKey)
                    (after, afterLabel) = try readPair(writeURL)
                }

                guard multisetEqual(after, intendedTags) else {
                    throw TagWriteError.verificationFailed("tag mismatch — expected \(intendedTags.sorted()) got \(after.sorted())")
                }
                let expectedLabel = normalizedLabel(intendedLabel) != normalizedLabel(beforeLabel) ? intendedLabel : beforeLabel
                guard normalizedLabel(afterLabel) == normalizedLabel(expectedLabel) else {
                    throw TagWriteError.verificationFailed("label mismatch — expected \(String(describing: expectedLabel)) got \(String(describing: afterLabel))")
                }

                // §9 inverse delta (re-adds what we removed, removes what we added, restores color).
                let beforeSet = Set(before), afterSet = Set(after)
                let inverse = TagDelta(
                    add: Array(beforeSet.subtracting(afterSet)),
                    remove: Array(afterSet.subtracting(beforeSet)),
                    color: normalizedLabel(afterLabel) != normalizedLabel(beforeLabel) ? .restoreLabel(beforeLabel) : nil
                )
                box.result = TagWriteResult(url: url, before: before, after: after,
                                            beforeLabel: beforeLabel, afterLabel: afterLabel, inverse: inverse)
            } catch {
                box.error = error
            }
        }
        if let coordError { throw TagWriteError.coordinationFailed(coordError.localizedDescription) }
        if let error = box.error { throw error }
        guard let result = box.result else { throw TagWriteError.coordinationFailed("coordination block did not run") }
        return result
    }

    // MARK: Helpers

    private static func readPair(_ url: URL) throws -> ([String], Int?) {
        let rv = try url.resourceValues(forKeys: [.tagNamesKey, .labelNumberKey])
        return (rv.tagNames ?? [], rv.labelNumber)
    }

    /// A small reference box so the synchronous coordination closure can hand results back out.
    private final class ResultBox { var result: TagWriteResult?; var error: Error? }
}

// MARK: - Matching helpers (used by app-level adapters)

/// Two tokens are "the same" for add-dedup: exact match, or case-insensitive for Read/Unread only.
public func isSameTag(_ a: String, _ b: String) -> Bool {
    a == b || (isReadStateWord(b) && a.caseInsensitiveCompare(b) == .orderedSame)
}

/// A token should be removed if it exactly equals the target, or (for Read/Unread) matches it
/// case-insensitively. Never substring — removing "Unread" never disturbs a subject "Read later".
public func shouldRemoveTag(_ token: String, matching target: String) -> Bool {
    token == target || (isReadStateWord(target) && token.caseInsensitiveCompare(target) == .orderedSame)
}

/// Whether a string is "Read" or "Unread" (case-insensitive).
public func isReadStateWord(_ s: String) -> Bool {
    s.caseInsensitiveCompare(ReadState.read.rawValue) == .orderedSame
        || s.caseInsensitiveCompare(ReadState.unread.rawValue) == .orderedSame
}

/// Multiset (order-independent) equality for tag arrays.
public func multisetEqual(_ a: [String], _ b: [String]) -> Bool { a.sorted() == b.sorted() }
