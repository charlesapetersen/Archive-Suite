import Foundation

/// **Where the two durable journals resolve to, and what the SHIPPED deleter does when it runs**
/// (W16.bat2-fu2) — headless, $0, no network, no keys.
///
/// Two gaps closed here, one cause. Until the journal directory became redirectable
/// (`OCRProcessor.pendingStateDirectory`), the default `makeBatchJournalDeleter` body — the one line on the
/// money path that actually removes `pending_batch.json` — could be verified only by reading it: no check
/// anywhere ran it (`BatchCancelWiringContract` replaces the seam before every Stop and never invokes the
/// default it inspects), so mutating that body to `{ }` left all 241 checks green. And with the path pinned
/// to Application Support, any future un-seamed deletion in the cancel block would have made *running
/// `test-batch-resume.sh`* the thing that destroyed the operator's live journal.
///
/// So this file is in two halves, and the order matters:
///
///  1. **The resolver fails closed.** `pendingStateDirectory(testFlag:overrideRoot:)` is pure in its inputs,
///     so every bad reading of the two environment variables is handed to it directly and must come back
///     with the REAL Application Support path. This is the half that protects production: a mis-read env var
///     here does not fail a test, it strands a paid batch by looking for its journal in the wrong directory.
///     A check that only proved "the override works when set" would pass on an implementation that silently
///     redirected in production, which is exactly the failure worth ruling out.
///
///  2. **The shipped deleter really deletes** — and only what it is allowed to. Gated behind a hard safety
///     guard (`redirectIsInForce`, run by the driver before ANY section): if the live resolution is not
///     redirected away from Application Support, the six destructive checks are skipped and a single FAIL is
///     emitted in their place, because the alternative is deleting a real paid batch's only local record to
///     satisfy a test. Nothing asserts a check count, so a refused run reports SOME FAILED — it cannot read
///     as a shorter green report.
///
/// ⚠️ **SCOPE.** This proves the journal's *location* and the *deleter's* behaviour. It does not prove the
/// rule that decides when a cancellation is confirmed (`BatchCancelContract`, section 13) or the arguments
/// `cancel()` feeds it (`BatchCancelWiringContract`, section 14), and it does not follow the poll that is
/// unwinding downstream of all of them — whose cancellation guards used to delete the journal regardless
/// (W16.bat3, now fixed and pinned by `BatchPollCancelContract`, section 17). A green section 16 alone does
/// not make pressing Stop safe end to end.
///
/// Run from `BatchResumeTestDriver` (section 16) under `BATCHRESUME_TEST=1`; see
/// `scripts/test-batch-resume.sh`, which is what sets `ARCHIVEPROC_TEST_STATE_ROOT`.
@MainActor
enum BatchJournalPathContract {

    /// `redirected` is `redirectIsInForce(_:)`'s verdict, taken by the driver BEFORE section 1 rather than
    /// here. That ordering is the point: sections 13–15 press Stop 80+ times through the real `cancel()`,
    /// and if the harness's redirect had silently failed to validate they would do it against the operator's
    /// own state. Learning that at section 16 would be too late to be a safeguard.
    static func run(check: (String, Bool) -> Void, redirected: Bool) async {
        theResolverFailsClosed(check)
        // Everything past here writes to, and deletes from, whatever the journal path resolves to.
        guard redirected else {
            // Six checks are skipped, not silently: this one FAILs in their place, and no caller asserts a
            // check count, so a refused run reports SOME FAILED rather than a shorter green report.
            check("journal path: the SHIPPED deleter was run against a redirected journal — NOT RUN, and the "
                  + "six checks that would have written to the journal path are SKIPPED (refused: the path "
                  + "did not resolve away from Application Support)", false)
            return
        }
        theWholeJournalPathIsRedirected(check)
        theDefaultDeleterReallyDeletes(check)
        await aStopWithTheRealDeleterInstalled(check)
    }

    // MARK: - 1. The resolver fails closed

    /// Every reading of the two variables that must NOT redirect, stated one at a time. `real` is what each
    /// of them has to come back with — read from the shipped function rather than rebuilt here, so this
    /// asks "did it refuse?" and not "did it produce a path I also wrote down".
    private static func theResolverFailsClosed(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let real = OCRProcessor.realPendingStateDirectory()
        let usable = fm.temporaryDirectory
            .appendingPathComponent("APJournalPath-usable-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: usable, withIntermediateDirectories: true)
        // A path that names a regular FILE, not a directory: a plausible typo (pointing the root at the
        // journal itself) and the one rejection that cannot be decided from the string alone.
        let notADirectory = fm.temporaryDirectory
            .appendingPathComponent("APJournalPath-file-\(UUID().uuidString).json")
        try? Data("{}".utf8).write(to: notADirectory)
        defer {
            try? fm.removeItem(at: usable)
            try? fm.removeItem(at: notADirectory)
        }

        // The whole point of the positive case below is that it differs from the fallback. If the temp
        // directory ever WERE the Application Support directory, "redirected" and "real" would be the same
        // answer and half this file would be vacuous.
        check("journal path: the usable override and the real path are genuinely different directories",
              usable.path != real.path && notADirectory.path != real.path)

        // The flag. Only the exact string "1" may enable anything.
        let flagRejections: [(String, String?)] = [
            ("unset", nil), ("empty", ""), ("zero", "0"), ("true", "true"),
            ("trailing space", "1 "), ("leading space", " 1"), ("leading zero", "01"),
            ("yes", "yes"), ("newline", "1\n"),
        ]
        var flagHeld = true
        var firstBadFlag: String?
        for (name, flag) in flagRejections {
            let resolved = OCRProcessor.pendingStateDirectory(testFlag: flag, overrideRoot: usable.path)
            if resolved.path != real.path {
                flagHeld = false
                if firstBadFlag == nil { firstBadFlag = name }
            }
        }
        check("journal path: only BATCHRESUME_TEST=\"1\" exactly may redirect — \(flagRejections.count) "
              + "near-misses all resolve to the real path"
              + (firstBadFlag.map { " [first bad: \($0)]" } ?? ""), flagHeld)

        // The override value, with the flag correctly set. Each of these is a way the variable can be wrong
        // that a `!= nil` test would wave through.
        let rootRejections: [(String, String?)] = [
            ("unset", nil), ("empty", ""), ("whitespace", "   "), ("tab", "\t"),
            ("relative", "state"), ("dot-relative", "./state"), ("parent-relative", "../state"),
            ("tilde", "~/state"), ("bare name", "pending_batch.json"),
            ("names a file, not a directory", notADirectory.path),
            // A directory that cannot be created because a FILE occupies a parent component.
            ("uncreatable", notADirectory.appendingPathComponent("nested").path),
        ]
        var rootHeld = true
        var firstBadRoot: String?
        for (name, root) in rootRejections {
            let resolved = OCRProcessor.pendingStateDirectory(testFlag: "1", overrideRoot: root)
            if resolved.path != real.path {
                rootHeld = false
                if firstBadRoot == nil { firstBadRoot = name }
            }
        }
        check("journal path: with the flag set, \(rootRejections.count) unusable override roots all still "
              + "resolve to the real path"
              + (firstBadRoot.map { " [first bad: \($0)]" } ?? ""), rootHeld)

        // Both wrong at once — the shape an accidental half-configuration takes.
        check("journal path: neither variable alone is enough",
              OCRProcessor.pendingStateDirectory(testFlag: nil, overrideRoot: nil).path == real.path
              && OCRProcessor.pendingStateDirectory(testFlag: "1", overrideRoot: nil).path == real.path
              && OCRProcessor.pendingStateDirectory(testFlag: nil, overrideRoot: usable.path).path == real.path)

        // …and the one case that MUST redirect. Without this the checks above are satisfied by a function
        // that ignores its arguments and always returns the real path — which would quietly disarm the
        // deleter checks below by making them refuse to run.
        check("journal path: the flag plus a usable absolute root redirects, and to exactly that root",
              OCRProcessor.pendingStateDirectory(testFlag: "1", overrideRoot: usable.path).path == usable.path)

        // The fallback is the operator's real directory, not some other invention.
        check("journal path: the real fallback is <Application Support>/ArchiveProcessor",
              real.lastPathComponent == "ArchiveProcessor"
              && real.deletingLastPathComponent().lastPathComponent == "Application Support")

        // The REAL branch, exercised end to end — against a FileManager that answers the Application Support
        // query with a scratch directory, so the operator's own `~/Library` is never the subject. Asserting
        // the side effect on the true path would be worthless: the resolutions above already created it, and
        // it pre-exists on any machine that has launched the app, so a deleted `createDirectory` would stay
        // green there.
        let scratchSupport = fm.temporaryDirectory
            .appendingPathComponent("APJournalPath-appsupport-\(UUID().uuidString)", isDirectory: true)
        let expectedScratchState = scratchSupport.appendingPathComponent("ArchiveProcessor", isDirectory: true)
        let scratchAbsentBefore = !fm.fileExists(atPath: expectedScratchState.path)
        let resolvedOnScratch = OCRProcessor.pendingStateDirectory(
            testFlag: nil, overrideRoot: nil, fileManager: ScratchApplicationSupport(root: scratchSupport))
        var scratchIsDirectory: ObjCBool = false
        let scratchCreated = fm.fileExists(atPath: expectedScratchState.path, isDirectory: &scratchIsDirectory)
            && scratchIsDirectory.boolValue
        try? fm.removeItem(at: scratchSupport)
        check("journal path: the real branch appends ArchiveProcessor to Application Support and CREATES it",
              scratchAbsentBefore && scratchCreated && resolvedOnScratch.path == expectedScratchState.path)

        // The create-the-directory SIDE EFFECT, proved rather than assumed. Asserting it on the real path is
        // worthless — 24 resolutions above already created it, and it pre-exists on any machine that has run
        // the app — so this uses a directory that provably did not exist a line ago. What depends on it is
        // the `.atomic` write in `savePendingBatch`/`savePendingRun`, which needs somewhere to put its
        // sibling temp file; drop the `createDirectory` and a crash-safe write becomes a failed one.
        let virgin = fm.temporaryDirectory
            .appendingPathComponent("APJournalPath-virgin-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        let absentBefore = !fm.fileExists(atPath: virgin.path)
        let handedOut = OCRProcessor.pendingStateDirectory(testFlag: "1", overrideRoot: virgin.path)
        var virginIsDirectory: ObjCBool = false
        let createdOnTheWayOut = fm.fileExists(atPath: virgin.path, isDirectory: &virginIsDirectory)
            && virginIsDirectory.boolValue
        try? fm.removeItem(at: virgin.deletingLastPathComponent())
        check("journal path: the directory is created before the URL is handed out, so an .atomic write has "
              + "somewhere to put its sibling temp file",
              absentBefore && createdOnTheWayOut && handedOut.path == virgin.path)

        // Two files, one directory — and they must stay two files. A cancellation is allowed to remove the
        // paid-batch journal; removing the interrupted run's manifest with it would discard cached results
        // that were already paid for. A drift tripwire rather than a test: both URLs are built from the same
        // directory plus a distinct constant, so this restates the implementation on purpose — it reddens if
        // someone gives the two journals separate roots or collides their names.
        check("journal path: both journals resolve into the same directory, under different names",
              OCRProcessor.pendingBatchURL.deletingLastPathComponent().path
                  == OCRProcessor.pendingRunURL.deletingLastPathComponent().path
              && OCRProcessor.pendingBatchURL.lastPathComponent == OCRProcessor.pendingBatchFileName
              && OCRProcessor.pendingRunURL.lastPathComponent == OCRProcessor.pendingRunFileName
              && OCRProcessor.pendingBatchURL.path != OCRProcessor.pendingRunURL.path)
    }

    // MARK: - 2. The safety guard — run FIRST, by the driver, not by this file

    /// The precondition for every destructive check here, and the whole suite's licence to press Stop
    /// through the real `cancel()`: this process's journal path must resolve somewhere that is NOT the
    /// operator's Application Support directory. Called from the top of `BatchResumeTestDriver.run()`, so a
    /// harness whose redirect silently failed to validate is caught before section 13 rather than after 15.
    ///
    /// Symlinks are resolved on both sides before comparing. Without that, an override pointing at a symlink
    /// to the real directory would satisfy a raw string compare and let the destructive checks below delete
    /// the operator's actual journal — a perverse value, but this comparison is the only thing standing
    /// between those checks and the money path, so it does not get to be approximate.
    static func redirectIsInForce(_ check: (String, Bool) -> Void) -> Bool {
        let real = OCRProcessor.realPendingStateDirectory().resolvingSymlinksInPath().path
        let live = OCRProcessor.pendingStateDirectoryFromEnvironment.resolvingSymlinksInPath().path
        let requested = ProcessInfo.processInfo
            .environment[OCRProcessor.pendingStateTestRootEnvKey]
            .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path }
        // Not merely "different from real": it must be the directory the harness actually asked for, and
        // that directory must not be the real one under any spelling — including a parent of it, which would
        // put the journals right back where they started.
        let redirected = live != real && requested != nil && live == requested
            && !real.hasPrefix(live + "/")
        check("journal path: this run's journal directory is the harness's own, not Application Support "
              + "(\(redirected ? "redirected" : "NOT redirected — set ARCHIVEPROC_TEST_STATE_ROOT"))",
              redirected)
        return redirected
    }

    // MARK: - 3. Write, read and delete all go to the redirected directory

    /// Not only the deleter: if the SAVE path still wrote to Application Support, a check that deleted a
    /// file from the temp directory would prove nothing about the journal the app actually keeps.
    private static func theWholeJournalPathIsRedirected(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let source = fm.temporaryDirectory
            .appendingPathComponent("APJournalPath-source-\(UUID().uuidString).pdf")
        try? Data("%PDF-1.4\n".utf8).write(to: source)
        defer { try? fm.removeItem(at: source) }

        // "The operator's journal was not disturbed" is stated as *unchanged*, never as *absent*. Asserting
        // the real path holds no journal would be red on any machine that has a live paid batch — i.e. this
        // check would fail exactly when the thing it protects is real, which is the failure mode
        // W16.bat2-fu3's review caught in the harness timeout. Reading bytes is safe; nothing here writes
        // to this path.
        let realJournal = OCRProcessor.realPendingStateDirectory()
            .appendingPathComponent(OCRProcessor.pendingBatchFileName)
        let realBefore = try? Data(contentsOf: realJournal)

        let saved = OCRProcessor.savePendingBatch(journal(chunkIds: ["batches/save-0"], files: [source]))
        let landedInTheRedirectedDirectory = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        let realUndisturbed = (try? Data(contentsOf: realJournal)) == realBefore
        // The production READ seam, not a hand-rolled decode: `pendingBatchFileURLs` is what a resume asks.
        let readBack = OCRProcessor().pendingBatchFileURLs
        OCRProcessor.deletePendingBatch()

        check("journal path: savePendingBatch writes into the redirected directory, leaving whatever is at "
              + "the real Application Support path untouched",
              saved != nil && landedInTheRedirectedDirectory && realUndisturbed
              && OCRProcessor.pendingBatchURL.path != realJournal.path)
        check("journal path: the production read path finds the journal that was just written there",
              readBack == [source])
    }

    // MARK: - 4. The default deleter's body — the line no check could run before

    /// THE regression check for W16.bat2-fu2. Builds a processor whose seams are untouched, asks it for the
    /// deleter production gets, and runs it against a real journal file. Neuter
    /// `makeBatchJournalDeleter`'s default to `{ }` — the mutation that left all 241 checks green — and this
    /// reddens. Point it at the wrong file and the second half reddens.
    private static func theDefaultDeleterReallyDeletes(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let runManifest = OCRProcessor.pendingRunURL
        let runBytes = Data(#"{"sentinel":"interrupted-run-manifest"}"#.utf8)
        try? runBytes.write(to: runManifest, options: .atomic)
        try? Data(#"{"batchId":"paid-job"}"#.utf8).write(to: OCRProcessor.pendingBatchURL, options: .atomic)
        let bothExisted = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
            && fm.fileExists(atPath: runManifest.path)

        // Untouched: no seam replaced, no batch installed. This is the value the shipped app runs with.
        let production = OCRProcessor()
        let deleter = production.makeBatchJournalDeleter(.paidBatchJournal)
        deleter()

        let batchGone = !fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
        let runSurvivedIntact = (try? Data(contentsOf: runManifest)) == runBytes
        try? fm.removeItem(at: runManifest)

        check("journal path: the DEFAULT journal deleter — the one production gets — really removes the "
              + "paid-batch journal from disk",
              bothExisted && batchGone)
        // The other half of the item: a deleter (or a future un-seamed deletion beside it) that also took
        // the interrupted-run manifest would discard results the operator already paid for.
        check("journal path: and it leaves the interrupted-run manifest byte-identical", runSurvivedIntact)
    }

    // MARK: - 5. A whole Stop with the real deleter installed

    /// Sections 13/14 prove the rule and the wiring with the deleter stubbed. This drives the real
    /// `cancel()` with the deleter LEFT AT ITS DEFAULT — only the network-touching canceller is stubbed — so
    /// what is observed is the operator's actual journal file, in the directory the app actually uses,
    /// disappearing (or not) for the two outcomes that matter.
    private static func aStopWithTheRealDeleterInstalled(_ check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let runManifest = OCRProcessor.pendingRunURL
        let runBytes = Data(#"{"sentinel":"survives-a-paid-batch-cancellation"}"#.utf8)

        /// One Stop: `refuse` decides whether the provider confirms every chunk.
        func stop(refusing refuse: Bool) async -> (existedBefore: Bool, survived: Bool,
                                                   runSurvived: Bool, message: String) {
            let chunkIds = ["batches/chunk-0", "batches/chunk-1"]
            let pending = journal(chunkIds: chunkIds, files: [])
            // The journal on disk is written by the production save path, so this is a real one.
            OCRProcessor.savePendingBatch(pending)
            try? runBytes.write(to: runManifest, options: .atomic)
            let existed = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)

            let processor = OCRProcessor()
            // The ONLY seam replaced: building a canceller opens no connection, but running one would.
            processor.makeBatchChunkCanceller = { context in
                OCRProcessor.BatchChunkCanceller(provider: context.provider,
                                                 cancelChunk: { _ in !refuse },
                                                 clientTypeName: "stub")
            }
            processor.activeBatch = OCRProcessor.BatchContext(
                batchId: chunkIds.joined(separator: ","), apiKey: "journal-path-not-a-key",
                model: model(), thinkingLevel: .high, provider: .gemini)
            processor.activePendingBatch = pending
            processor.cancel()
            await processor.batchCancellationTask?.value

            let survived = fm.fileExists(atPath: OCRProcessor.pendingBatchURL.path)
            let runSurvived = (try? Data(contentsOf: runManifest)) == runBytes
            OCRProcessor.deletePendingBatch()
            try? fm.removeItem(at: runManifest)
            return (existed, survived, runSurvived, processor.statusMessage)
        }

        let confirmed = await stop(refusing: false)
        check("journal path: a CONFIRMED Stop, with the real deleter installed, removes the journal file itself",
              confirmed.existedBefore && !confirmed.survived)

        let unconfirmed = await stop(refusing: true)
        // The money-critical direction, and the reason the deleter is behind a rule at all: a paid job the
        // provider would not confirm as cancelled may still be running, and the journal is the only way back.
        check("journal path: an UNCONFIRMED Stop leaves the real journal file on disk, and says so",
              unconfirmed.existedBefore && unconfirmed.survived
              && unconfirmed.message == OCRProcessor.batchCancellationNotConfirmedMessage)
        // Neither outcome may take the interrupted-run manifest with it. This is the tripwire for the
        // un-seamed deletion `BatchCancelWiringContract`'s seam structurally cannot see.
        check("journal path: neither outcome touches the interrupted-run manifest",
              confirmed.runSurvived && unconfirmed.runSurvived)
    }

    // MARK: - Fixtures

    /// A `FileManager` that answers the Application Support query with a scratch directory. It is what lets
    /// the REAL branch of `pendingStateDirectory` — the one the shipped app takes — be checked end to end
    /// without `~/Library/Application Support` ever being the subject of the assertion.
    private final class ScratchApplicationSupport: FileManager, @unchecked Sendable {
        private let root: URL
        init(root: URL) {
            self.root = root
            super.init()
        }
        override func urls(for directory: FileManager.SearchPathDirectory,
                           in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
            directory == .applicationSupportDirectory
                ? [root] : super.urls(for: directory, in: domainMask)
        }
    }

    /// A synthetic model — never sent anywhere, and built by hand so no check depends on `CustomModelStore`.
    private static func model() -> LLMModel {
        LLMModel(id: "journal-path", displayName: "Journal Path", provider: .gemini,
                 supportsThinking: false, returnsMd: false,
                 inputCostPer1M: 0, outputCostPer1M: 0, batchDiscount: 0)
    }

    /// A v1 paid-batch journal. `savePendingBatch` derives its `batchId` from `submittedChunkIds`, so the
    /// value passed here is the one the persistence path is allowed to overwrite.
    private static func journal(chunkIds: [String], files: [URL]) -> OCRProcessor.PendingBatch {
        OCRProcessor.PendingBatch(
            batchId: chunkIds.joined(separator: ","), provider: .gemini, model: model(),
            thinkingLevel: .high, fileURLs: files,
            outputDirectory: FileManager.default.temporaryDirectory,
            enableTagging: false, sendPreviousImage: false, submittedAt: Date(),
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: chunkIds)
    }
}
