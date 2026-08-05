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
//   §6 write-target identity re-verification — when the caller passes the identity captured at
//      discovery (`expectedIdentity:`), the resolved URL's identity is re-checked INSIDE the block,
//      just before writing; a mismatch (or a now-unresolvable target) ABORTS so a file that was
//      moved/replaced under the same path is never tagged. Uses `fileResourceIdentifier` (a pure
//      read), NEVER `.documentIdentifierKey` (which assigns & persists an id — a mutation).
//   §7 label written only when the transform changes it; drift otherwise restored.
//   §8 verify by re-read — multiset equality (order-independent) + label check.
//   §9 inverse delta derived from the actual before/after diff.
//   §10 in-process per-resolved-path serialization — the whole read→modify→verify→write above is
//       mutually excluded PER FILE, so two concurrent in-process writers to the SAME path cannot
//       both read the pre-write state and clobber each other (a lost update). NSFileCoordinator's
//       .contentIndependentMetadataOnly does NOT provide this (it grants two metadata-only write
//       claims concurrently). CROSS-PROCESS writers are explicitly OUT OF SCOPE — an in-process
//       lock cannot cover a second process; only §1 coordination mediates across processes at all.
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

/// A multiplicity-aware (multiset) tag change — the shape of an *undo inverse* that must restore the
/// exact OCCURRENCE COUNT of each token, not merely its presence. A peer to `TagDelta`, which stays
/// set-like for ordinary user edits; this exists ALONGSIDE it so the undo path can be made
/// occurrence-lossless (consumers rewired in W15.tu2) without changing user-edit semantics.
/// Occurrence-only per the owner decision (2026-07-18): counts are preserved, order is not (macOS
/// reorders tags on write and the SPEC already compares tag arrays as a multiset, so position is
/// unobservable). Unlike the `Set`-based `TagDelta` inverse, this never drops a duplicate.
public struct TagOccurrenceDelta: Sendable, Equatable {
    /// Tokens to add, WITH multiplicity — a token appears once per occurrence to restore.
    public var add: [String]
    /// Tokens to remove, WITH multiplicity — a token appears once per occurrence to strip.
    public var remove: [String]
    /// Optional Finder color-label change (no multiplicity — a label is a single value).
    public var color: TagDelta.ColorChange?

    public init(add: [String] = [], remove: [String] = [], color: TagDelta.ColorChange? = nil) {
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
    /// Set-based (collapses duplicates) — kept for existing consumers; the undo path prefers
    /// `occurrenceInverse` once rewired (W15.tu2).
    public let inverse: TagDelta
    /// The occurrence-aware (multiset) inverse — restores each token's exact COUNT, so undoing an edit
    /// that touched a duplicated tag never loses an occurrence. Additive alongside `inverse` (W15.tu1);
    /// the undo/restore path is wired to it in W15.tu2. Empty for a no-op.
    public let occurrenceInverse: TagOccurrenceDelta

    public init(url: URL, before: [String], after: [String],
                beforeLabel: Int?, afterLabel: Int?, inverse: TagDelta,
                occurrenceInverse: TagOccurrenceDelta = TagOccurrenceDelta()) {
        self.url = url; self.before = before; self.after = after
        self.beforeLabel = beforeLabel; self.afterLabel = afterLabel
        self.inverse = inverse; self.occurrenceInverse = occurrenceInverse
    }

    /// True when nothing actually changed (idempotent no-op).
    public var isNoOp: Bool { before.sorted() == after.sorted() && normalizedLabel(beforeLabel) == normalizedLabel(afterLabel) }
}

public enum TagWriteError: Error, Sendable, Equatable {
    case unreadable(String)          // current tags could not be read — refused (Safety §3)
    case verificationFailed(String)  // post-write re-read did not match the intended result
    case coordinationFailed(String)  // NSFileCoordinator could not obtain access
    case identityMismatch(String)    // resolved write target is not the file captured at discovery (Safety §6)
}

/// An opaque snapshot of a file's on-disk identity, captured at discovery/selection and re-verified
/// immediately before a tag write (inside the coordination block) to guard against writing to the
/// WRONG file after a Finder move/replace (Safety Protocol §6).
///
/// Backed by `URLResourceValues.fileResourceIdentifier` — a kernel-assigned token compared with
/// `isEqual(_:)` (two identifiers are equal iff they refer to the same file-system object; not
/// persistent across restarts, which is fine — capture and re-verify happen within one session).
/// We deliberately use `.fileResourceIdentifierKey`, NEVER `.documentIdentifierKey`: the latter
/// *assigns & persists* an identifier on read — a mutation forbidden by §6.
public struct FileIdentity: @unchecked Sendable {
    // Opaque kernel token; only ever compared via isEqual: — never inspected, decoded, or mutated.
    // `@unchecked Sendable` is safe: the token is an immutable, value-like identity object.
    private let token: any NSObjectProtocol

    private init(token: any NSObjectProtocol) { self.token = token }

    /// Capture the identity of the file currently at `url`, or `nil` if it has none — e.g. the file
    /// does not exist, or the volume does not vend a resource identifier. A `nil` capture means the
    /// caller cannot request identity re-verification for this file (pass `nil` → no §6 check).
    public static func capture(_ url: URL) -> FileIdentity? {
        guard let token = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier
        else { return nil }
        return FileIdentity(token: token)
    }

    /// True when `other` refers to the same on-disk file-system object as this identity.
    public func matches(_ other: FileIdentity) -> Bool { token.isEqual(other.token) }
}

/// nil and 0 both mean "no color label"; normalize so they compare equal.
/// Public so app-level adapters (Reader TagWriter, Processor MacOSTagger) can use it
/// in their transform closures without duplicating the mapping.
public func normalizedLabel(_ label: Int?) -> Int { label ?? 0 }

/// Serializes the full read→modify→verify→write sequence of `CoordinatedTagWriter.write` PER resolved
/// file path (Safety §10), so two concurrent IN-PROCESS writers to the SAME file cannot both observe
/// the pre-write state and clobber each other (a lost update). Different paths are never serialized
/// against each other — unrelated tag writes still run fully concurrently.
///
/// A refcounted registry of per-path `NSLock`s: an entry is created on the first waiter and discarded
/// once the last holder releases, so the map never grows without bound. A synchronous `NSLock` (not an
/// actor) keeps `write` synchronous — every caller (Reader `TagWriter`, Processor `MacOSTagger`, Notes
/// `NotesTagProjector`) invokes it synchronously, so an `async` hop would be a breaking change across
/// all three apps for no benefit here.
///
/// OUT OF SCOPE — cross-process writers: this is an IN-PROCESS lock. A second PROCESS, or any writer
/// that does not funnel through `CoordinatedTagWriter.write`, mutating the same file is NOT covered —
/// only `NSFileCoordinator` (§1) mediates across processes, and it does not mutually-exclude two
/// metadata-only write claims. Do not read this as a cross-process guarantee.
///
/// Non-reentrant by design: a `transform` closure must NOT call `CoordinatedTagWriter.write` on the
/// same path (a nested same-path write would self-deadlock). No caller does — the closures are pure.
private final class PathWriteSerializer: @unchecked Sendable {
    private final class Entry { let lock = NSLock(); var waiters = 0 }
    private let master = NSLock()
    private var entries: [String: Entry] = [:]

    /// Block until exclusive access for `key` is held. Balanced by exactly one `release(key)`.
    func acquire(_ key: String) {
        master.lock()
        let entry: Entry
        if let existing = entries[key] { entry = existing }
        else { let e = Entry(); entries[key] = e; entry = e }
        entry.waiters += 1
        master.unlock()
        entry.lock.lock()   // wait OUTSIDE `master` so unrelated paths never block on this one
    }

    /// Release exclusive access for `key`, discarding the per-path lock once no one else is waiting.
    func release(_ key: String) {
        master.lock()
        guard let entry = entries[key] else { master.unlock(); return }  // defensive; never expected
        entry.waiters -= 1
        if entry.waiters == 0 { entries[key] = nil }
        master.unlock()
        entry.lock.unlock()
    }
}

public enum CoordinatedTagWriter {

    /// One serializer instance for the whole process — the shared choke-point's per-path lock table.
    private static let serializer = PathWriteSerializer()

    /// The per-path serialization key: a best-effort canonical path (symlinks + `.`/`..` resolved) so
    /// two URLs that name the SAME file map to one lock. Best-effort — if two equivalent URLs ever
    /// resolve differently we merely lose serialization for that edge (no worse than before the lock);
    /// the common case (all three apps pass a file's canonical URL) is fully covered.
    private static func serializationKey(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The one place that writes tags. `transform` receives the FRESHLY-READ current state (inside the
    /// coordination block) and returns the intended new state, or nil for a no-op. Everything else —
    /// the trustworthy-read guard, the write, verification, drift restore, and inverse derivation —
    /// is enforced here so no caller can bypass it.
    ///
    /// `expectedIdentity` (Safety §6): pass the `FileIdentity` captured at discovery/selection to have
    /// the resolved URL's identity re-verified INSIDE the coordination block before any write; a
    /// mismatch aborts with `.identityMismatch` so a file moved/replaced under the same path is never
    /// tagged. `nil` (the default) skips the check — behavior is unchanged for callers that don't opt in.
    public static func write(
        _ url: URL,
        expectedIdentity: FileIdentity? = nil,
        transform: ([String], Int?) -> ([String], Int?)?
    ) throws -> TagWriteResult {
        // §10 in-process per-resolved-path serialization. Hold a per-file lock across the ENTIRE
        // read→modify→verify→write below, so two concurrent in-process writers to the same file
        // can't both read pre-write state and clobber each other (a lost update). Acquired BEFORE
        // coordination so only one thread per path ever enters the NSFileCoordinator block; released
        // via `defer` on every exit (success, throw, or no-op). Cross-process writers are NOT covered
        // (see PathWriteSerializer). Different paths never contend, so unrelated writes stay parallel.
        let serialKey = serializationKey(for: url)
        serializer.acquire(serialKey)
        defer { serializer.release(serialKey) }

        let box = ResultBox()
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: &coordError) { writeURL in
            do {
                // §6 write-target identity re-verification. If the caller captured the file's identity
                // at discovery/selection, re-read the resolved URL's identity NOW (inside coordination,
                // just before writing) and ABORT on mismatch — the file at this path was moved/replaced,
                // so writing here would tag a DIFFERENT file. Pure read (fileResourceIdentifier), never
                // documentIdentifier. This runs BEFORE the fresh tag read so nothing is written on abort.
                if let expectedIdentity {
                    guard let current = FileIdentity.capture(writeURL) else {
                        throw TagWriteError.identityMismatch("write target has no resolvable identity (moved or deleted since discovery)")
                    }
                    guard current.matches(expectedIdentity) else {
                        throw TagWriteError.identityMismatch("write target identity changed since discovery — refusing to tag a different file")
                    }
                }

                // §2/§3 fresh read inside coordination; a read FAILURE aborts (never treated as empty).
                // Routed through `TagReading.read` — the ONLY primitive that can tell "no tags" apart
                // from "couldn't read the tags". Reading `resourceValues` directly here is what made
                // this comment a lie for as long as it has existed: the call does not throw for a file
                // with unreadable extended attributes, so `rv.tagNames ?? []` handed the transform an
                // empty `before` for a file carrying real tags, and line ~271 then wrote that delta —
                // measured turning ["Unread","Subj","P9"] into ["Read"] (W26.deny). Do not inline this
                // read again.
                let before: [String]
                let beforeLabel: Int?
                switch TagReading.read(writeURL) {
                case let .success(names, label):
                    before = names
                    beforeLabel = label
                case let .failure(why):
                    throw TagWriteError.unreadable(why)
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
                // §9 (W15.tu1) occurrence-aware inverse — carries per-token multiplicity so undo can
                // restore a duplicate the set-based `inverse` collapses. Additive: `inverse` above is
                // unchanged; consumers switch to this in W15.tu2.
                let occurrenceInverse = tagOccurrenceInverse(before: before, after: after,
                                                             beforeLabel: beforeLabel, afterLabel: afterLabel)
                box.result = TagWriteResult(url: url, before: before, after: after,
                                            beforeLabel: beforeLabel, afterLabel: afterLabel,
                                            inverse: inverse, occurrenceInverse: occurrenceInverse)
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

    /// The §8 post-write re-read. Also routed through `TagReading.read`: a re-read whose tags cannot be
    /// read is not a verification, and coercing it to `[]` would let a write to an EMPTY tag array
    /// "verify" against a file nobody can read. An unreadable re-read is a failed verification.
    private static func readPair(_ url: URL) throws -> ([String], Int?) {
        switch TagReading.read(url) {
        case let .success(names, label):
            return (names, label)
        case let .failure(why):
            throw TagWriteError.verificationFailed("post-write re-read failed: \(why)")
        }
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

/// Computes the occurrence-aware (multiset) inverse of a tag write: the delta that, applied to the
/// post-write state, restores the pre-write state while preserving each token's exact OCCURRENCE
/// COUNT — not just its presence. Occurrence-only per the owner decision (count, not order): macOS
/// reorders tags on write and the SPEC compares tag arrays as a multiset, so restoring position is
/// unobservable. Unlike the `Set`-based `TagDelta` inverse (which collapses `["A","A"]`→`["A"]`),
/// this never drops a duplicate. Color restore matches the set inverse (a label has no multiplicity).
public func tagOccurrenceInverse(before: [String], after: [String],
                                 beforeLabel: Int?, afterLabel: Int?) -> TagOccurrenceDelta {
    TagOccurrenceDelta(
        add: multisetDifference(before, minus: after),     // more copies in `before` → re-add the surplus
        remove: multisetDifference(after, minus: before),  // more copies in `after`  → strip the surplus
        color: normalizedLabel(afterLabel) != normalizedLabel(beforeLabel) ? .restoreLabel(beforeLabel) : nil
    )
}

/// The multiset difference `a − b`: each token repeated by how many MORE times it appears in `a`
/// than in `b` (never negative). Order follows first appearance in `a`; occurrence-only (count, not
/// position). E.g. `multisetDifference(["A","A","B"], minus: ["A"]) == ["A","B"]`.
func multisetDifference(_ a: [String], minus b: [String]) -> [String] {
    var remaining: [String: Int] = [:]
    for t in b { remaining[t, default: 0] += 1 }
    var out: [String] = []
    for t in a {
        if let n = remaining[t], n > 0 { remaining[t] = n - 1 }  // cancelled by a copy in `b`
        else { out.append(t) }                                   // surplus occurrence → part of a − b
    }
    return out
}
