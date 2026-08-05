import Foundation
import Combine
import ArchiveCore

/// Discovers the tagged-PDF universe by **walking the filesystem** (`ArchiveCore.CorpusWalker`).
///
/// The master predicate is unchanged — a file belongs to the library iff it carries a `Read` or
/// `Unread` tag (`CorpusWalker.tracksReadState`, shared so discovery and the write path cannot drift).
/// Tag facets here are for display/sort/filter only; the authoritative read for a write is done inside
/// `TagWriter`.
///
/// **Why this is not `NSMetadataQuery` any more (W26, owner directive 2026-08-04).** On 2026-08-04 the
/// owner pointed the Reader at 1,849 correctly-tagged PDFs and was told *"No Read/Unread-tagged PDFs
/// were found in this folder."* The Data volume's Spotlight index was dead — `mdfind` returned 0 for
/// that folder, for `$HOME`, for `/Applications` and for the real corpus — and this class had **no
/// Release filesystem fallback at all** (the working walk was `#if DEBUG`). Two failures: the index
/// went blind, and the app then blamed the files. The old "no per-file disk I/O (the fast path at
/// 150k)" justification was already void: `ContentIndexer` opens and extracts text from every PDF
/// anyway, and a measured full walk of the real corpus (123,028 files) takes 10.15 s single-threaded.
///
/// So discovery is now deterministic, and — the part that actually fixes the incident — it can say
/// **"I could not look"** separately from **"there is nothing here"**: see `phase` / `LibraryPhase`.
@MainActor
final class ArchiveLibrary: ObservableObject {
    @Published private(set) var files: [ArchiveFile] = []
    /// Replaced `isGathering: Bool` outright (plan §7a.4 / the walk2 item): one boolean could not both
    /// drive a list-blanking spinner and gate destructive content-index pruning once discovery
    /// revalidates behind rows that are already on screen.
    @Published private(set) var phase: LibraryPhase = .noRoot
    @Published private(set) var scopeDescription = "No folder selected"

    /// The root being walked, so `rescan()` needs no argument.
    private var root: URL?

    /// When discovery last completed a clean pass on a root that held still. Dates `.revalidating`
    /// and `.degraded`, so the UI can say what it knew and when instead of an undated wrong claim.
    private var lastSettled: Date?

    // MARK: - The write-vs-walk ordering guard (replaced ~80 lines of TTL/convergence overlay)
    //
    // The deleted `PendingWrite` machinery (`pending`, `settleTimer`, `overrideTTL`,
    // `overrideDecision`, `sameTags`/`sameLabel`, `armSettleTimer` — and its 8-case test file) existed
    // for exactly one reason: Spotlight kept re-emitting a file's OLD `kMDItemUserTags` after a
    // verified write, so a laggy reload clobbered the correct value. There is no index to lag now.
    //
    // But deleting it outright would have removed the only WRITE-VS-WALK ORDERING guard, and the
    // plan's original justification ("a re-walk reads the same disk through the same primitive, so it
    // converges") confused convergence with sequencing (plan §7a.2). The real hazard: the owner marks
    // 2,000 rows Read; a rescan starts around write #300 and reads files #300–#2000 *while their
    // writes are still pending*; its emission then lands after `applyVerifiedWrites` and publishes
    // pre-write values over verified ones.
    //
    // The replacement is a sequence number, not a timer: one monotonic counter stamps both scan starts
    // and verified writes, and a row whose write is NEWER than the pass's start keeps the verified
    // value. No TTL, no timer, no value comparison — an ordering guarantee instead of a race that
    // usually settles.
    private struct VerifiedWrite { let after: [String]; let afterLabel: Int?; let seq: UInt64 }
    private var verifiedWrites: [URL: VerifiedWrite] = [:]
    private var clock: UInt64 = 0
    /// Generation of the pass whose result may still be published. Bumped per pass, so a superseded
    /// pass's late completion is dropped rather than publishing stale rows over a newer root's
    /// (`ContentIndexer`'s generation-token discipline, same shape).
    private var currentScan: UInt64 = 0
    private var inFlight: ScanCancellation?

#if DEBUG
    /// Launch/defaults key that pins the app to a fixture root (XCUITest + unit tests).
    private static let fixtureRootKey = "ARUITestRootPath"
#endif

    // MARK: - Starting and re-running discovery

    /// Start (or restart) discovery within a scope. `nil` clears the library.
    ///
    /// Note what is gone with Spotlight: there is no whole-Mac scope any more. The old `nil`-scope
    /// branch set `NSMetadataQueryLocalComputerScope` and was documented "future use" — dead code that
    /// only a Spotlight index could have served, and walking the whole Mac is not something this app
    /// should ever do.
    func start(scope: URL?) {
        inFlight?.cancel()
        inFlight = nil
        files = []
        verifiedWrites.removeAll()      // no override may leak across roots
        lastSettled = nil
        root = scope
        guard let scope else {
            phase = .noRoot
            scopeDescription = "No folder selected"
            return
        }
        scopeDescription = scope.lastPathComponent
        phase = .firstScan(done: 0, seen: 0)
        beginScan(root: scope)
    }

    /// Re-walk the current root, keeping the rows already on screen (File ▸ Rescan Archive Folder, ⌘⌥R).
    ///
    /// This ships **with** the swap, not after it: deleting `NSMetadataQueryDidUpdate` removed the
    /// app's only refresh mechanism, and `CorpusWatcher` (FSEvents) is the next item — so without a
    /// manual rescan the Reader would have no way at all to notice an external change.
    func rescan() {
        guard let root else { return }
        inFlight?.cancel()
        // `.firstScan` blanks the list, which is honest only when there is nothing to blank.
        phase = files.isEmpty ? .firstScan(done: 0, seen: 0) : .revalidating(asOf: lastSettled)
        beginScan(root: root)
    }

    private func beginScan(root: URL) {
        clock += 1
        let generation = clock
        currentScan = generation
        let token = ScanCancellation()
        inFlight = token

#if DEBUG
        // A fixture root scans SYNCHRONOUSLY — same walker, same predicate, same failure accounting;
        // only the delivery thread differs. That distinction is the whole point: pre-W26 this key
        // selected a different discovery *mechanism* (the `#if DEBUG` fixture loader), which is how a
        // Release build shipped with no filesystem discovery at all. Two shipped tests
        // (`DocumentPageLinkTests`, `RootMarkerStateTests`) assert on `files` the moment
        // `NavigationModel()` returns, and the XCUITest fixture lane's `waitForRows` timings were
        // calibrated against a synchronous load.
        if UserDefaults.standard.string(forKey: Self.fixtureRootKey) != nil {
            finish(LibraryScan.pass(root: root, isCancelled: { token.isCancelled }),
                   generation: generation)
            return
        }
#endif
        // Progress only — NOT rows. See `finish`: rows are published once per pass, atomically.
        let onBatch: @Sendable (CorpusScanBatch) -> Void = { batch in
            let found = batch.entries.count
            let seen = batch.filesSeen
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.reportProgress(generation: generation,
                                                                found: found, seen: seen) }
            }
        }
        LibraryScan.onDedicatedThread(root: root,
                                     isCancelled: { token.isCancelled },
                                     onBatch: onBatch) { [weak self] pass in
            MainActor.assumeIsolated { self?.finish(pass, generation: generation) }
        }
    }

    /// Real progress — a count Spotlight could never give. Only meaningful during a first scan; a
    /// revalidation deliberately leaves the on-screen rows and their counts alone.
    private func reportProgress(generation: UInt64, found: Int, seen: Int) {
        guard generation == currentScan, case let .firstScan(done, _) = phase else { return }
        phase = .firstScan(done: done + found, seen: seen)
    }

    /// Publish a finished pass: rows first, then the verdict about how much of it to trust.
    ///
    /// **Rows are published once, atomically, at the end of the pass** — batches drive the progress
    /// counter only. Two reasons, both load-bearing: (1) `pruneIfSettled` computes
    /// `indexedUnderRoot.subtracting(currentPaths)`, so a PARTIAL row list makes everything not yet
    /// walked look deleted (plan §7a.11's sharpening) — publishing progressively is exactly what would
    /// endanger it; (2) `NavigationModel.libraryDidChange` rebuilds the folder tree, subject cache and
    /// smart-folder counts per emission, so 200 partial emissions at corpus scale would be quadratic
    /// work for a list the user cannot use yet anyway.
    private func finish(_ pass: DiscoveryPass, generation: UInt64) {
        guard generation == currentScan else { return }   // superseded pass — publish nothing
        inFlight = nil
        let next = DiscoveryHealth.phase(after: pass.result, root: pass.rootStability,
                                         finishedAt: Date(), lastSettled: lastSettled)
        files = merged(pass: pass, generation: generation,
                       absenceIsAuthoritative: next.isSettled)
        if case let .settled(asOf, _) = next { lastSettled = asOf }
        phase = next
    }

    /// Build the row list from a completed pass. Two rules, and both are the point of this wave.
    ///
    /// 1. **A pass whose absences are not authoritative keeps every unseen existing row** (plan
    ///    §5.13 tier 1 / §7a.3). That includes a directly-unreadable file, every descendant of a
    ///    directory the enumerator could not enter, and a clean-looking short walk whose root changed
    ///    underneath it. "I could not reach it" must not render as "it is gone". A third-party tag
    ///    removal may therefore remain visible until the next clean pass — the deliberately conservative
    ///    answer when the same pass cannot prove absence.
    /// 2. **A verified write newer than this pass's start wins** (the §7a.2 ordering guard above).
    private func merged(pass: DiscoveryPass, generation: UInt64,
                        absenceIsAuthoritative: Bool) -> [ArchiveFile] {
        let result = pass.result
        var out: [ArchiveFile] = []
        out.reserveCapacity(result.entries.count)
        var placed = Set<URL>()

        for entry in result.entries {
            placed.insert(entry.url)
            if let write = verifiedWrites[entry.url], write.seq > generation {
                // The walk read this file BEFORE the write landed; the write's verified re-read wins.
                guard CorpusWalker.tracksReadState(write.after) else { continue }
                out.append(Self.row(entry, tagNames: write.after, labelNumber: write.afterLabel))
            } else {
                out.append(Self.row(entry, tagNames: entry.tagNames, labelNumber: entry.labelNumber))
            }
        }

        if !absenceIsAuthoritative {
            for row in files where !placed.contains(row.url) {
                out.append(row)
            }
        }

        // GC: an override this pass has now overtaken is finished. Anything newer than the pass stays,
        // so a *second* stale pass cannot resurrect a pre-write value either.
        verifiedWrites = verifiedWrites.filter { $0.value.seq > generation }
        return out
    }

    // MARK: - Verified writes

    /// Reflect a batch of *verified* `TagWriter` results in the model immediately, so rows leave a
    /// filtered view at once, and stamp them so a walk that started earlier cannot undo them.
    ///
    /// Pass only verified (non-throwing) results — a failed write must not move its row (Safety §11).
    /// The displayed value is `TagWriter`'s re-read `.after`/`.afterLabel` (ground truth), never a
    /// reconstruction from the model's own possibly-stale tags. Display-only: no disk write, no read.
    ///
    /// All five call sites (`mark`, group edit, inline edit, corpus-wide rename, undo) already hand in
    /// exactly that verified value, so this is now a **direct row replacement** rather than an overlay
    /// consulted on every subsequent emission.
    ///
    /// One deliberate behaviour change: a write that leaves the file with **no** Read/Unread tag drops
    /// the row from the library, because the membership predicate no longer holds. Spotlight used to do
    /// this a beat later, on its next update; doing it here is the same end state, immediately, and
    /// without a live query it is the only thing that would.
    func applyVerifiedWrites(_ results: [TagWriteResult]) {
        guard !results.isEmpty else { return }
        var replacements: [URL: VerifiedWrite] = [:]
        for r in results {
            clock += 1
            let write = VerifiedWrite(after: r.after, afterLabel: r.afterLabel, seq: clock)
            verifiedWrites[r.url] = write
            replacements[r.url] = write
        }
        files = files.compactMap { f in
            guard let write = replacements[f.url] else { return f }
            guard CorpusWalker.tracksReadState(write.after) else { return nil }
            return Self.rebuilt(f, after: write.after, afterLabel: write.afterLabel)
        }
    }

    // MARK: - Row construction

    private static func row(_ entry: CorpusEntry, tagNames: [String], labelNumber: Int?) -> ArchiveFile {
        ArchiveFile(url: entry.url,
                    name: entry.url.lastPathComponent,
                    fileType: shortType(uti: entry.contentTypeIdentifier, url: entry.url),
                    tags: DocumentTags.parse(raw: tagNames, labelNumber: labelNumber),
                    // `.contentModificationDateKey`, deliberately: a Finder-tag write changes ctime,
                    // not mtime, so this is the right key for the content-index freshness check and
                    // the wrong one for detecting a tag change (plan §5.12).
                    contentModified: entry.contentModified)
    }

    private static func rebuilt(_ f: ArchiveFile, after: [String], afterLabel: Int?) -> ArchiveFile {
        ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                    tags: DocumentTags.parse(raw: after, labelNumber: afterLabel),
                    contentModified: f.contentModified)
    }

    private static func shortType(uti: String?, url: URL) -> String {
        if uti == "com.adobe.pdf" { return "PDF" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}

/// One-way cancellation bit shared between the main actor and the walking thread.
private final class ScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
