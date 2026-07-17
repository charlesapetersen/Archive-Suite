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

public enum CoordinatedTagWriter {

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
