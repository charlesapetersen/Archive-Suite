import Foundation
import ArchiveCore

// ============================================================================================
//  NotesTagProjector — the AUDITED Finder-tag mirror for Archive Notes.
//
//  Reimplements every TagWriter invariant (CoordinatedTagWriter.write) for the narrow projection
//  use case: Notes mirrors an item's title-cased front-matter subjects and canonical Quality facet
//  (`Q1`...`Q3`) onto the note's own .md file via Finder tags.
//
//  This is the ONLY place Notes touches file-level tag metadata. It writes ONLY files under
//  <NotesStore>/items/<uuid>/ (component-boundary guard). It never touches color labels,
//  never moves/renames/deletes/content-writes, and never touches the archive corpus.
//
//  Invariants (each citing TagWriter / CoordinatedTagWriter):
//   §1 Single audited choke-point + coordinated metadata-only write (TagWrite.swift:91).
//   §2 Fresh read inside coordination (TagWrite.swift:93-102).
//   §3 Trustworthy-read guard — read failure aborts, never coerced to [] (TagReading.swift:6-9).
//   §4 Lossless delta: remove only previously-managed; add only desired (TagWrite.swift:44-50).
//   §5 Only adds/removes projected tokens, except the explicit one-way retired-marker cleanup.
//      Every removal is an exact whole-string match.
//   §6 Dedup projected tokens by adding only tokens that are not already present (TagWrite.swift:48).
//   §7 No label writes. Verify label unchanged after write (drift guard).
//   §8 Verify by re-read, multiset-equal (TagWrite.swift:127).
//   §9 Per-path in-process serialization (W15.tu3): concurrent projections of the SAME note file
//      are mutually excluded inside CoordinatedTagWriter (TagWrite.swift Safety §10), so two
//      parallel writes cannot each read pre-write state and clobber each other (a lost update).
//      Cross-PROCESS writers remain out of scope — an in-process lock cannot cover them.
// ============================================================================================

enum NotesTagProjector {
    /// The former membership token is a one-way cleanup exception to the usual "remove only what
    /// this caller previously managed" rule. The owner chose the clean end state: remove every
    /// legacy exact-match stamp on the next projection, while a current front-matter subject of the
    /// same spelling remains in `desired` and therefore survives.
    private static let retiredTokens: Set<String> = ["ArchiveSuite"]

    enum ProjectError: Error, Sendable {
        case unreadable(String)
        case verificationFailed(String)
        case coordinationFailed(String)
        case outsideItemDir(String)
    }

    /// Reconcile the Finder tags on `url` (a note's own .md file) so that the managed tokens
    /// match `desired`, preserving all non-managed tokens verbatim.
    ///
    /// - Parameters:
    ///   - desired: The managed tokens we want present (from `NotesTagVocabulary.managedTokens`).
    ///   - previouslyManaged: The managed tokens we wrote last time (so we remove only tokens WE
    ///     own that are now gone). Empty on first projection (add-only, safe).
    ///   - url: The note's .md file URL.
    ///   - itemDir: The item's directory URL (for the component-boundary guard).
    ///   - expectedIdentity: Optional identity captured immediately after the front-matter write. When
    ///     supplied, the audited writer rejects a delayed projection against a newer replacement at
    ///     the same path.
    ///
    /// - Returns: The managed set actually present after the write (persist as next call's
    ///   `previouslyManaged`).
    ///
    /// - Throws: `ProjectError` on read failure, verification failure, coordination failure, or
    ///   if the URL escapes the item directory.
    static func project(
        _ desired: Set<String>,
        previouslyManaged: Set<String>,
        to url: URL,
        itemDir: URL,
        qualityToken: String? = nil,
        expectedIdentity: FileIdentity? = nil
    ) throws -> Set<String> {
        // Component-boundary guard: the URL must be under the item's directory.
        // resolvingSymlinksInPath() resolves symlinks (not just lexical `..`), preventing a
        // symlink inside itemDir from escaping to an arbitrary target.
        // Append "/" to the dir path so "/items/abc" doesn't match "/items/abc-evil/".
        let stdURL = url.standardizedFileURL.resolvingSymlinksInPath().path
        let stdDir = itemDir.standardizedFileURL.resolvingSymlinksInPath().path
        let dirPrefix = stdDir.hasSuffix("/") ? stdDir : stdDir + "/"
        guard stdURL.hasPrefix(dirPrefix) else {
            throw ProjectError.outsideItemDir("URL \(url.path) is not under \(itemDir.path)")
        }

        #if DEBUG
        // §5 (W8) belt-and-suspenders: under a unit-test harness OR the GUI-drive store override,
        // a projector tag write MUST target scratch. This mechanically aborts a test or GUI drive
        // that ever aims a Finder-tag write at a non-scratch path (the real store or, worse, the
        // corpus). It is OFF in the real DEBUG app (no test env, no UITest override) and compiled
        // out of Release entirely, so ordinary tag writes to the real store are never affected.
        if inTestOrGUIDriveContext {
            precondition(
                isScratchPath(stdURL),
                "NotesTagProjector: refusing a tag write outside scratch during tests/GUI-drive: \(stdURL)")
        }
        #endif

        let result = try CoordinatedTagWriter.write(url, expectedIdentity: expectedIdentity) { currentTags, currentLabel in
            // §4 Lossless delta: compute what to remove and what to add.
            // Remove previously managed tokens that are no longer desired, plus the explicitly
            // retired legacy membership token. This is exact whole-string matching; no prefix or
            // case-folding can remove a nearby user tag.
            let toRemove = previouslyManaged.subtracting(desired)
                .union(retiredTokens.subtracting(desired))
            var newTags = currentTags.filter { token in
                !toRemove.contains(token)
            }

            // A user may legitimately choose a Q-looking subject such as `Q1`. ArchiveCore parses
            // the *last* Q token as the Quality facet, so preserve every such subject but force the
            // actual front-matter Quality token to the end of the raw tag array. Without this, set
            // iteration (or a pre-existing order) could make a Q-looking subject override the
            // authoritative Quality in Reader. Re-appending this one token is metadata-only and
            // leaves the subject's spelling intact.
            if let qualityToken {
                precondition(desired.contains(qualityToken),
                             "the explicit Quality token must also be a desired managed token")
                newTags.removeAll { $0 == qualityToken }
            }

            // Add desired subjects in stable order (dedup — §6). Keep the explicit Quality token
            // out of this loop: it is appended last below for ArchiveCore's last-token-wins parser.
            for token in desired.subtracting(qualityToken.map { [$0] } ?? []).sorted()
                where !newTags.contains(token) {
                newTags.append(token)
            }
            if let qualityToken, !newTags.contains(qualityToken) {
                newTags.append(qualityToken)
            }

            // No-op: if tags unchanged, skip the write.
            if newTags == currentTags { return nil }

            // §7 Never change the label — return the current label unchanged.
            return (newTags, currentLabel)
        }

        // Map CoordinatedTagWriter errors to ProjectError for a cleaner API surface.
        // (CoordinatedTagWriter already enforces §1-§3, §7-§8 internally.)

        // §7 drift guard: verify the label was not changed by our tag-array write.
        if normalizedLabel(result.afterLabel) != normalizedLabel(result.beforeLabel) {
            throw ProjectError.verificationFailed(
                "label drifted from \(String(describing: result.beforeLabel)) to \(String(describing: result.afterLabel))")
        }

        // Return the managed tokens that are actually on the file now.
        let afterSet = Set(result.after)
        return desired.filter { afterSet.contains($0) }
    }

    /// Recover `previouslyManaged` when the index DB is wiped (no persisted state).
    /// Intersects the file's current tags with the recomputed candidate managed set.
    /// Conservative: a token we never wrote is never in the result, so no accidental removal.
    static func recoverPreviouslyManaged(for item: Item, from url: URL) -> Set<String> {
        let readResult = TagReading.read(url)
        guard let currentTags = readResult.tagNames else { return [] }
        let candidates = NotesTagVocabulary.managedTokens(for: item)
        return candidates.intersection(currentTags)
    }

    // MARK: - Scratch-write guard (W8 §5)

    /// Whether `path` is under a known scratch prefix — the system temp dir (`mktemp` /
    /// `NSTemporaryDirectory()`, incl. `/private/var/folders/…`), `/tmp`, or an `AN-GUI-Fixture`
    /// store. Pure + total; symlink-resolved on both sides so `/var` vs `/private/var` never causes
    /// a false negative. Backs the DEBUG test/GUI-drive precondition (and is unit-tested directly).
    static func isScratchPath(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let tmpPrefix = tmp.hasSuffix("/") ? tmp : tmp + "/"
        if resolved == tmp || resolved.hasPrefix(tmpPrefix) { return true }
        for prefix in ["/private/var/folders/", "/private/tmp/", "/tmp/"] {
            if resolved.hasPrefix(prefix) { return true }
        }
        return resolved.contains("/AN-GUI-Fixture/") || resolved.hasSuffix("/AN-GUI-Fixture")
    }

    #if DEBUG
    /// True only in the two contexts where a projector write must stay in scratch: running under a
    /// unit-test harness, or with the GUI-drive store override active. False in the real DEBUG app.
    private static var inTestOrGUIDriveContext: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty { return true }
        return false
    }
    #endif
}
