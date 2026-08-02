import Foundation
import AppKit

/// Headless, $0 self-test of the **Process Files crash-resume manifest** (feature G2), gated by
/// `BATCHRESUME_TEST=1` (inert in normal use). Uses synthetic files in a temp dir — no OCR, no network,
/// no cost, no GUI interaction — to prove the durable-resume mechanisms and their Tier-2 data-safety
/// hard rules directly, without a full crash+relaunch E2E (which is owner-GUI-gated):
///   1. The manifest round-trips through the real crash-safe (`.atomic`) write + JSON decode path.
///   2. A run fingerprint MATCHES the same input+output+settings and DIFFERS when any of them change,
///      so a resume only applies to the intended job (Tier-2 rule e — mismatched manifests ignored).
///   3. A torn/tampered manifest (valid JSON, inconsistent stored fingerprint) is rejected, not applied.
///   4. Corrupt (non-JSON) manifest bytes decode to nil (ignored).
///   5. Resume SKIPS a pre-completed file — `remainingIndices` excludes the done index (Tier-2 rule a:
///      never re-OCR a completed file → no double cost).
///   6. A completed file's output PDF is confirmed on disk (Tier-2 rule c), and a DIFFERENT source that
///      shares its base filename gets a fresh, non-colliding output path (Tier-2 rule b: no overwrite).
///   7. The self-consistency guard runs on the DISK-ROUND-TRIPPED (loaded-from-JSON) manifest, not just
///      the in-memory struct — accepting an honest one and rejecting a tampered one after a real round trip
///      — and a legacy manifest (no `completedOutputPaths`) decodes with that field nil (backward-compat).
///   8. B7 regression: two sources sharing a base filename, assigned outputs in COMPLETION order that
///      differs from index order, each resolve back to the SAME output PDF they hold on disk (association
///      preserved via the persisted path map) — whereas the legacy index-order derivation would SWAP them.
///   9. P-1/P-2: `exportOriginals` (dual output) is persisted + round-trips in both PendingRun and
///      PendingBatch (so a resume restores it), a legacy manifest decodes it as nil (backward-compat), and
///      a batch manifest persists the ORIGINAL input files (not the ephemeral temp JPEGs) with a matching
///      fingerprint — the temp-path fingerprint provably diverges.
///  10. V2 non-batch manifests round-trip and apply a complete immutable runtime snapshot; their identity
///      is input-order-sensitive, detects runtime tampering, rejects unknown/malformed snapshots, and
///      leaves the legacy manifest/fingerprint path readable.
///  11. V1 paid-batch journals round-trip ordered/consumed chunk IDs and per-file output associations,
///      preserve partial submission, reopen missing outputs without another create, reject malformed
///      lifecycle state, and retain pre-journal comma-separated compatibility.
///  12. The three batch clients' **provider response-shape contract** — every status/result body shape
///      Anthropic, Gemini and Mistral are accepted in, parsed headlessly from literal fixtures
///      (`BatchParseContract`, W16.bat1). No network, no keys, no cost.
///  13. The **`cancel()` journal-retention rule** (`BatchCancelContract`, W16.bat2): the paid-batch recovery
///      journal is deleted if and only if every chunk's server-side cancellation was confirmed — swept over
///      every provider × chunk-count × refusal shape, against a real file. Scope: the RULE, not the whole
///      Stop path — the poll's own cancellation guards used to delete the journal first regardless
///      (W16.bat3), so a green section 13 alone does NOT mean pressing Stop is safe end to end; that half
///      is section 17.
///  14. The **`cancel()` WIRING** (`BatchCancelWiringContract`, W16.bat2-fu): section 13 proves the rule, this
///      proves `cancel()` feeds it the truth — the live batch's own context, a canceller that closes over
///      *that provider's own client* (not merely one labelled with it), the journal's acknowledged chunk IDs
///      rather than its decoy batch ID, the paid-batch journal and no other durable file, the kept-journal
///      warning being assigned and the resume banner refreshed, nothing at all when there is no live batch,
///      and no second cancellation when Stop is pressed twice. Real `cancel()`, stubbed seams, a real temp
///      file. Its header lists what it still does NOT cover (the default deleter, W16.bat6) — read it before
///      citing a green section 14.
///  15. The **interrupted-batch TAIL** (`BatchInterruptTailContract`, W16.bat4): sections 13/14 are about
///      Stop; this is about a run that ends itself with a paid job possibly still alive. The real
///      `finishInterruptedBatchPoll()` — the one tail both paid-batch entry points now run — recomputes the
///      resume banner (the Resume control every interruption message names, and the half that was missing on
///      a FIRST run), deletes exactly this run's own temp PDF→JPEG conversions and nothing else in the
///      directory (including two decoys named like the durable manifests), and leaves the interruption
///      message, the run's results and the interrupted-RUN manifest untouched — swept over every start state
///      the four interrupted exits can arrive in. Since W16.bat4-fu one of its sections writes a real journal
///      at the shipped path (same redirect gate as 16–18, restored byte for byte afterwards) so the recomputed
///      banners are compared against a read that found something, and so a tail that deleted the journal the
///      app really keeps is caught and not just one named like it. Its header scopes what it does not cover
///      (the two call sites themselves, which need a real paid submission to drive).
///  16. **Where the journals resolve, and what the SHIPPED deleter does** (`BatchJournalPathContract`,
///      W16.bat2-fu2): sections 13–15 all replace the deleter seam, so its default body — the line that
///      actually removes `pending_batch.json` — was verified by reading it. The journal directory is now
///      redirectable (`ARCHIVEPROC_TEST_STATE_ROOT`, honoured only alongside `BATCHRESUME_TEST=1` and only
///      as a usable absolute directory), so this runs the real deleter against a real journal file, and
///      pins the fail-closed direction against every bad reading of the two variables.
///  17. **Stop during the POLL** (`BatchPollCancelContract`, W16.bat3): everything above stops at `cancel()`;
///      this follows the cancellation into the poll unwinding alongside it, which is where the journal was
///      really being deleted. The poll's two cancellation exits now report themselves interrupted, so the
///      first run's tail keeps the journal and a whole cancelled `resumeBatch` leaves the real file on disk
///      with the Resume control rendered. Both guards precede any provider call, so nothing is requested.
///      Its section 5 (W16.bat6) covers the other half of that promise — the operator being *told* — by
///      pressing Stop with a live `processingTask` and asserting the kept-journal warning is still the
///      message on screen once the cancelled run has finished writing its own.
///  18. **No journal MUTATION fails in silence** (`BatchMutationReportContract`, W16.bat3-fu): a layer below
///      section 17, at the three mutators a paid batch advances its journal through. `performBatchOCR`'s
///      FIFTH interrupted exit guards on `markBatchSubmissionComplete()`, whose missing-journal failure —
///      the shape a Stop mid-submit lands in — returned `false` having set nothing, leaving the run to be
///      judged on the flag a PREVIOUS run left behind. Pins both directions: a failed mutation always
///      reports, a healthy one never does, and reporting removes nothing from disk.
///  19. **What the interrupted submission TELLS the operator** (`BatchSubmissionMessageContract`,
///      W16.bat3-fu2): section 18 pins that a failed mutation says something; this pins that the sentence is
///      true. `performBatchOCR`'s catch counted acknowledged jobs out of the journal `cancel()` had just
///      nil'd, so on the money path it reported "no server ID was received; the journal was kept" with paid
///      jobs already created and without looking at the file. Now every clause is a measurement — the count
///      from a tally a Stop cannot clear, "kept" only about a file on disk, created-but-unrecorded jobs
///      named, and the mutator's own explanation leading rather than overwritten. Drives the real exit
///      against a real journal (same redirect gate).
///
/// Writes a PASS/FAIL report to `BATCHRESUME_TEST_OUT` (or a temp file) + NSLog. Test scaffolding only.
/// Sections 1–11 operate on explicit temp manifest URLs via the `_testWrite/_testRead` hooks and sections
/// 12–15 write no durable manifest at all; section 16 uses the shipped paths deliberately, which is safe
/// because `scripts/test-batch-resume.sh` redirects them into its own temp directory and
/// `redirectIsInForce` — checked at the top of `run()`, before section 13 — refuses the destructive checks
/// otherwise. So no run of this driver reads, writes or deletes either of the user's real recovery
/// manifests. It does still *create* `<Application Support>/ArchiveProcessor` if it is absent, because
/// resolving the real path makes the directory as it always has; an empty directory, never a file in it.
@MainActor
enum BatchResumeTestDriver {
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment["BATCHRESUME_TEST"] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    static func run() async {
        let fm = FileManager.default
        var results: [String] = []
        func check(_ name: String, _ ok: Bool) {
            results.append("\(ok ? "PASS" : "FAIL"): \(name)")
            NSLog("BATCHRESUME \(ok ? "PASS" : "FAIL"): \(name)")
        }

        // FIRST, before any section runs: is the durable-journal directory actually redirected away from the
        // operator's Application Support state (W16.bat2-fu2)? Sections 13–15 press Stop 80+ times through
        // the real `cancel()`, and the redirect fails CLOSED and silently — so if `$ARCHIVEPROC_TEST_STATE_ROOT`
        // did not validate, those sections would be running against the operator's own journals. Section 16
        // uses this verdict to decide whether its destructive checks may run at all; asking at section 16
        // would answer the question after everything risky had already happened.
        let journalsAreRedirected = BatchJournalPathContract.redirectIsInForce(check)

        let tmp = fm.temporaryDirectory.appendingPathComponent("APBatchResume-\(UUID().uuidString)", isDirectory: true)
        let inDir = tmp.appendingPathComponent("in", isDirectory: true)
        let outDir = tmp.appendingPathComponent("out", isDirectory: true)
        try? fm.createDirectory(at: inDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        // Two synthetic inputs (contents irrelevant — no OCR is performed).
        let img0 = inDir.appendingPathComponent("img0.jpg")
        let img1 = inDir.appendingPathComponent("img1.jpg")
        try? Data("0".utf8).write(to: img0)
        try? Data("1".utf8).write(to: img1)
        let files = [img0, img1]

        // The non-batch PendingRun fingerprint does not include tagging mode (it resumes under the live
        // UI mode), so pass nil — matching how startProcessing stores it.
        let fingerprint = OCRProcessor.runFingerprint(
            files: files, outputDirectory: outDir, taggingMode: nil, enableTagging: true, batchMode: false)

        // A manifest that says file 0 is DONE (its OCR result cached) and file 1 is still pending.
        let done = OCRResult(text: "cached text for file 0", classification: nil,
                             rotationDegrees: 0, errorMessage: nil, errorCode: nil)
        let run = OCRProcessor.PendingRun(
            provider: .gemini, model: LLMProvider.gemini.models[0], thinkingLevel: nil,
            fileURLs: files, outputDirectory: outDir, enableTagging: true, enableSegmentJSON: true,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: ["0": done], runFingerprint: fingerprint)

        // --- 1: round-trip through the real crash-safe write + decode path. ---
        let manifestURL = tmp.appendingPathComponent("pending_run.json")
        let wrote = OCRProcessor._testWritePendingRun(run, to: manifestURL)
        check("manifest written via atomic (.atomic) path", wrote && fm.fileExists(atPath: manifestURL.path))
        let loaded = OCRProcessor._testReadPendingRun(from: manifestURL)
        check("manifest round-trips (decodes back)", loaded != nil)
        check("round-trip preserves the input set", loaded?.fileURLs == files)
        check("round-trip preserves the DONE file's cached OCR text",
              loaded?.completedResults["0"]?.text == "cached text for file 0")
        check("round-trip preserves the fingerprint", loaded?.runFingerprint == fingerprint)

        // --- 2: fingerprint matches the same job, differs when input/output/settings change. ---
        let sameAgain = OCRProcessor.runFingerprint(
            files: files.reversed(), outputDirectory: outDir, taggingMode: nil,
            enableTagging: true, batchMode: false)
        check("fingerprint is input-order-independent (same job matches)", sameAgain == fingerprint)
        let diffFiles = OCRProcessor.runFingerprint(
            files: [img0], outputDirectory: outDir, taggingMode: nil, enableTagging: true, batchMode: false)
        let diffOut = OCRProcessor.runFingerprint(
            files: files, outputDirectory: inDir, taggingMode: nil, enableTagging: true, batchMode: false)
        let diffTag = OCRProcessor.runFingerprint(
            files: files, outputDirectory: outDir, taggingMode: nil, enableTagging: false, batchMode: false)
        let diffBatch = OCRProcessor.runFingerprint(
            files: files, outputDirectory: outDir, taggingMode: nil, enableTagging: true, batchMode: true)
        // Batch manifests DO include tagging mode → changing it changes the batch fingerprint.
        let batchAuto = OCRProcessor.runFingerprint(
            files: files, outputDirectory: outDir, taggingMode: .automatic, enableTagging: true, batchMode: true)
        let batchNone = OCRProcessor.runFingerprint(
            files: files, outputDirectory: outDir, taggingMode: TaggingMode.none, enableTagging: true, batchMode: true)
        check("fingerprint differs for a different input set", diffFiles != fingerprint)
        check("fingerprint differs for a different output dir", diffOut != fingerprint)
        check("fingerprint differs when tagging is toggled", diffTag != fingerprint)
        check("fingerprint differs for batch vs non-batch", diffBatch != fingerprint)
        check("batch fingerprint differs for a different tagging mode", batchAuto != batchNone)

        // --- 3: self-consistency guard accepts the honest manifest, rejects a tampered one. ---
        check("self-consistent manifest is accepted", OCRProcessor.pendingRunIsSelfConsistent(run))
        var tampered = run
        tampered.runFingerprint = "deadbeefdeadbeef"   // valid JSON, but fingerprint no longer matches fields
        check("tampered/torn manifest is rejected (ignored, not misapplied)",
              !OCRProcessor.pendingRunIsSelfConsistent(tampered))

        // --- 4: corrupt (non-JSON) bytes decode to nil → ignored. ---
        let corruptURL = tmp.appendingPathComponent("corrupt.json")
        try? Data("{ not valid json ".utf8).write(to: corruptURL)
        check("corrupt manifest bytes decode to nil (ignored)",
              OCRProcessor._testReadPendingRun(from: corruptURL) == nil)

        // --- 5: resume skips the pre-completed file (anti-double-cost). ---
        let remaining = OCRProcessor.remainingIndices(
            totalFiles: run.fileURLs.count, completedResults: run.completedResults)
        check("resume SKIPS the done file 0 (never re-OCR'd)", !remaining.contains(0))
        check("resume CONTINUES with the pending file 1", remaining == [1])

        // --- 6: output-on-disk confirmation (rule c) + no-overwrite of a sibling (rule b). ---
        // The DONE file's output PDF from the first pass; a resume must confirm it on disk and reuse it.
        let out0 = outDir.appendingPathComponent("img0.pdf")
        try? Data("first-pass pdf for file 0".utf8).write(to: out0)
        check("completed file's output PDF is confirmed on disk (rule c)", fm.fileExists(atPath: out0.path))

        // A DIFFERENT source that shares the base name "img0" (e.g. img0.jpg from another box) must NOT
        // be routed to the already-reserved img0.pdf.
        let processor = OCRProcessor()
        processor.outputURLMap[img0] = out0                       // reserve img0.pdf for the real file 0
        let sibling = inDir.appendingPathComponent("box2").appendingPathComponent("img0.jpg")
        let assigned = processor.uniqueOutputURL(baseName: "img0", ext: "pdf", in: outDir, for: sibling)
        check("a colliding-base sibling gets a fresh, non-clobbering output path (rule b)",
              assigned.lastPathComponent != "img0.pdf" && !fm.fileExists(atPath: assigned.path))
        check("reserving the same source again is idempotent (reuses its path)",
              processor.uniqueOutputURL(baseName: "img0", ext: "pdf", in: outDir, for: img0) == out0)
        check("the first-pass output PDF is untouched by the sibling assignment",
              fm.fileExists(atPath: out0.path))

        // --- 7: self-consistency guard on the DISK-ROUND-TRIPPED manifest (not just the in-memory one). ---
        check("round-tripped (from-disk) manifest passes self-consistency",
              loaded.map { OCRProcessor.pendingRunIsSelfConsistent($0) } ?? false)
        var tamperedRun = run
        tamperedRun.runFingerprint = "deadbeefdeadbeef"
        let tamperedURL = tmp.appendingPathComponent("tampered_run.json")
        _ = OCRProcessor._testWritePendingRun(tamperedRun, to: tamperedURL)
        let tamperedLoaded = OCRProcessor._testReadPendingRun(from: tamperedURL)
        check("round-tripped (from-disk) tampered manifest is rejected",
              tamperedLoaded != nil && !OCRProcessor.pendingRunIsSelfConsistent(tamperedLoaded!))
        // Backward-compat: `run` was built without completedOutputPaths → the loaded copy has it nil.
        check("legacy manifest (no completedOutputPaths) round-trips with the field nil",
              loaded?.completedOutputPaths == nil)

        // --- 8: B7 regression — duplicate base name assigned OUT OF COMPLETION ORDER. ---
        // Two sources share the base name "00001" across folders. In the original pass file index 1 (boxB)
        // COMPLETED FIRST → it was assigned the plain "00001.pdf"; index 0 (boxA) completed SECOND →
        // "00001 (2).pdf". So the persisted completion-order assignment is the INVERSE of index order.
        let boxA = inDir.appendingPathComponent("boxA").appendingPathComponent("00001.jpg")   // index 0
        let boxB = inDir.appendingPathComponent("boxB").appendingPathComponent("00001.jpg")   // index 1
        let dupSources = [boxA, boxB]
        let outPlain = outDir.appendingPathComponent("00001.pdf")       // on disk for index 1 (finished 1st)
        let outSecond = outDir.appendingPathComponent("00001 (2).pdf")  // on disk for index 0 (finished 2nd)
        let dupResults: [String: OCRResult] = [
            "0": OCRResult(text: "boxA doc", classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil),
            "1": OCRResult(text: "boxB doc", classification: nil, rotationDegrees: 0, errorMessage: nil, errorCode: nil)]
        let dupPaths: [String: String] = ["0": outSecond.path, "1": outPlain.path]
        let dupRun = OCRProcessor.PendingRun(
            provider: .gemini, model: LLMProvider.gemini.models[0], thinkingLevel: nil,
            fileURLs: dupSources, outputDirectory: outDir, enableTagging: true, enableSegmentJSON: true,
            enableCollectionSegmentation: false, confirmCollectionIDs: false,
            reviewDocumentSegmentation: false, preOCRedInput: false, previousTextCharCount: 0,
            sendPreviousImage: false, customPrompt: nil, startedAt: Date(), gatewayConfig: nil,
            completedResults: dupResults, completedOutputPaths: dupPaths,
            runFingerprint: OCRProcessor.runFingerprint(
                files: dupSources, outputDirectory: outDir, taggingMode: nil, enableTagging: true, batchMode: false))
        let dupURL = tmp.appendingPathComponent("dup_run.json")
        _ = OCRProcessor._testWritePendingRun(dupRun, to: dupURL)
        let dupLoaded = OCRProcessor._testReadPendingRun(from: dupURL)
        check("persisted output-path map survives the disk round-trip",
              dupLoaded?.completedOutputPaths == dupPaths)
        // Resolve outputs from the LOADED manifest — exactly what resumeRun does.
        let resolved = OCRProcessor.resolveResumeOutputURLs(
            completedResults: dupLoaded?.completedResults ?? [:],
            completedOutputPaths: dupLoaded?.completedOutputPaths,
            sourceURLs: dupLoaded?.fileURLs ?? [],
            outputDirectory: dupLoaded?.outputDirectory ?? outDir)
        check("resume maps boxA/00001 (index 0) to its ON-DISK 00001 (2).pdf (association preserved)",
              resolved[0]?.standardizedFileURL == outSecond.standardizedFileURL)
        check("resume maps boxB/00001 (index 1) to its ON-DISK 00001.pdf (association preserved)",
              resolved[1]?.standardizedFileURL == outPlain.standardizedFileURL)
        // Prove the bug is real: the legacy index-order derivation SWAPS the association (index 0 →
        // plain 00001.pdf, which on disk belongs to index 1). The persisted-path fix prevents this.
        let legacyResolved = OCRProcessor.resolveResumeOutputURLs(
            completedResults: dupResults, completedOutputPaths: nil,
            sourceURLs: dupSources, outputDirectory: outDir)
        check("legacy index-order derivation WOULD swap (index 0 → 00001.pdf); persisted-path fix diverges",
              legacyResolved[0]?.lastPathComponent == "00001.pdf"
              && resolved[0]?.lastPathComponent != legacyResolved[0]?.lastPathComponent)

        // --- 9: P-1/P-2 — exportOriginals is persisted (dual output survives resume) and the batch
        // manifest persists the ORIGINAL input files, not the ephemeral temp JPEGs. ---
        // P-1 (run): a PendingRun round-trips exportOriginals=true, and a legacy manifest (field absent)
        // decodes it as nil so resume falls back to the live setting (backward-compat).
        var runExport = run
        runExport.exportOriginals = true
        let exportURL = tmp.appendingPathComponent("export_run.json")
        _ = OCRProcessor._testWritePendingRun(runExport, to: exportURL)
        let exportLoaded = OCRProcessor._testReadPendingRun(from: exportURL)
        check("PendingRun round-trips exportOriginals=true (P-1: dual output survives resume)",
              exportLoaded?.exportOriginals == true)
        check("legacy PendingRun (no exportOriginals) decodes the field as nil (backward-compat)",
              loaded?.exportOriginals == nil)

        // P-2 (batch): a PendingBatch built from ORIGINAL files persists those originals (not temp JPEGs)
        // and stays self-consistent (fingerprint computed over the originals); exportOriginals round-trips.
        let batch = OCRProcessor.PendingBatch(
            batchId: "batch-test", provider: .gemini, model: LLMProvider.gemini.models[0],
            thinkingLevel: nil, fileURLs: files, outputDirectory: outDir, enableTagging: true,
            enableCollectionSegmentation: false, sendPreviousImage: false, submittedAt: Date(),
            enableSegmentJSON: true, confirmCollectionIDs: false, reviewDocumentSegmentation: false,
            customPrompt: nil, taggingMode: .automatic,
            runFingerprint: OCRProcessor.runFingerprint(
                files: files, outputDirectory: outDir, taggingMode: .automatic,
                enableTagging: true, batchMode: true, preserveInputOrder: true),
            exportOriginals: true)
        let batchData = try? JSONEncoder().encode(batch)
        let batchLoaded = batchData.flatMap { try? JSONDecoder().decode(OCRProcessor.PendingBatch.self, from: $0) }
        check("PendingBatch persists the ORIGINAL input files (P-2: not ephemeral temp JPEGs)",
              batchLoaded?.fileURLs == files)
        check("PendingBatch round-trips exportOriginals=true (P-1)",
              batchLoaded?.exportOriginals == true)
        check("PendingBatch is self-consistent — fingerprint over the persisted originals matches (P-2)",
              batchLoaded.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false)
        let batchV2ReorderedFingerprint = OCRProcessor.runFingerprint(
            files: files.reversed(), outputDirectory: outDir, taggingMode: .automatic,
            enableTagging: true, batchMode: true, preserveInputOrder: true)
        check("v2 PendingBatch fingerprint is input-order-sensitive for index-keyed provider results",
              batchV2ReorderedFingerprint != batch.runFingerprint)
        if let batchData,
           var legacyObject = try? JSONSerialization.jsonObject(with: batchData) as? [String: Any] {
            legacyObject.removeValue(forKey: "fingerprintVersion")
            let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject)
            let legacyBatch = legacyData.flatMap {
                try? JSONDecoder().decode(OCRProcessor.PendingBatch.self, from: $0)
            }
            check("legacy paid batch without a fingerprint version remains resumable",
                  legacyBatch?.fingerprintVersion == nil
                  && (legacyBatch.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false))
        } else {
            check("legacy paid batch compatibility fixture is constructible", false)
        }
        // A batch manifest that (as before the fix) persisted the TEMP-JPEG paths instead would fingerprint
        // over the temp paths — a DIFFERENT identity than the originals the resume UI presents, so it would
        // fail the match. Prove the two fingerprints diverge (why persisting originals is required).
        let tempPaths = [inDir.appendingPathComponent("\(UUID().uuidString).jpg"),
                         inDir.appendingPathComponent("\(UUID().uuidString).jpg")]
        let fpOriginals = OCRProcessor.runFingerprint(
            files: files, outputDirectory: outDir, taggingMode: .automatic, enableTagging: true, batchMode: true)
        let fpTemp = OCRProcessor.runFingerprint(
            files: tempPaths, outputDirectory: outDir, taggingMode: .automatic, enableTagging: true, batchMode: true)
        check("temp-JPEG fingerprint differs from the originals' (P-2: why originals must be persisted)",
              fpOriginals != fpTemp)

        // --- 10: B11 — complete, versioned, order-sensitive non-batch resume configuration. ---
        func runtimeConfig(
            schemaVersion: Int = OCRProcessor.PendingRunRuntimeConfig.currentSchemaVersion,
            mergeDocuments: Bool = true,
            imageScale: Double = 0.37,
            boundaries: [Bool] = [true, false]
        ) -> OCRProcessor.PendingRunRuntimeConfig {
            OCRProcessor.PendingRunRuntimeConfig(
                schemaVersion: schemaVersion,
                taggingMode: .copySource,
                passSourceTags: true,
                rotationMode: .off,
                reviewRotation: true,
                mergeDocuments: mergeDocuments,
                tagVocabulary: ["Correspondence", "Receipts"],
                imageScale: imageScale,
                exportOriginals: false,
                preGroupedBoundaries: boundaries,
                preGroupedTypes: [.box, .document],
                preGroupedPriorities: ["P10", nil],
                preGroupedYears: [1944, 1944],
                preGroupedMonths: [6, 6],
                preGroupedSubjects: [["Correspondence"], []],
                standardImageMB: 4.5,
                ocrWorkerCount: 2,
                pdfImageMB: 1.5,
                textColumns: 3,
                exportedImageMB: 2.5,
                gatewayUpstreamProvider: nil)
        }
        func makeV2Run(files orderedFiles: [URL], config: OCRProcessor.PendingRunRuntimeConfig)
            -> OCRProcessor.PendingRun {
            var value = OCRProcessor.PendingRun(
                provider: .gemini, model: LLMProvider.gemini.models[0], thinkingLevel: nil,
                fileURLs: orderedFiles, outputDirectory: outDir,
                enableTagging: true, enableSegmentJSON: false,
                enableCollectionSegmentation: true, confirmCollectionIDs: true,
                reviewDocumentSegmentation: true, preOCRedInput: false,
                previousTextCharCount: 321, sendPreviousImage: true,
                customPrompt: "v2 prompt", startedAt: Date(), gatewayConfig: nil,
                completedResults: [:], runFingerprint: nil,
                exportOriginals: false, localAgent: nil, runtimeConfig: config)
            value.runFingerprint = OCRProcessor.pendingRunFingerprintV2(value)
            return value
        }

        let v2 = makeV2Run(files: files, config: runtimeConfig())
        let v2URL = tmp.appendingPathComponent("pending_run_v2.json")
        _ = OCRProcessor._testWritePendingRun(v2, to: v2URL)
        let v2Loaded = OCRProcessor._testReadPendingRun(from: v2URL)
        check("v2 runtime snapshot survives the disk round-trip",
              v2Loaded?.runtimeConfig?.taggingMode == .copySource
              && v2Loaded?.runtimeConfig?.imageScale == 0.37
              && v2Loaded?.runtimeConfig?.tagVocabulary == ["Correspondence", "Receipts"]
              && v2Loaded?.runtimeConfig?.preGroupedSubjects == [["Correspondence"], []]
              && v2Loaded?.runtimeConfig?.ocrWorkerCount == 2
              && v2Loaded?.runtimeConfig?.textColumns == 3)
        check("round-tripped v2 manifest passes structural + fingerprint validation",
              v2Loaded.map { OCRProcessor.pendingRunIsSelfConsistent($0) } ?? false)

        let reorderedV2 = makeV2Run(files: files.reversed(), config: runtimeConfig())
        check("v2 fingerprint is input-order-sensitive because cached results are index-keyed",
              reorderedV2.runFingerprint != v2.runFingerprint)

        var runtimeTampered = v2
        runtimeTampered.runtimeConfig = runtimeConfig(mergeDocuments: false)
        check("v2 fingerprint rejects a changed runtime setting",
              !OCRProcessor.pendingRunIsSelfConsistent(runtimeTampered))
        var orderTampered = v2
        orderTampered = makeV2Run(files: files.reversed(), config: runtimeConfig())
        orderTampered.runFingerprint = v2.runFingerprint
        check("v2 fingerprint rejects reordered inputs with the old index association",
              !OCRProcessor.pendingRunIsSelfConsistent(orderTampered))

        var completionState = v2
        completionState.completedResults["0"] = done
        completionState.completedOutputPaths = ["0": out0.path]
        check("v2 fingerprint rejects completion-state mutation until it is re-signed",
              !OCRProcessor.pendingRunIsSelfConsistent(completionState))
        completionState.runFingerprint = OCRProcessor.pendingRunFingerprintV2(completionState)
        check("v2 fingerprint accepts a coherently updated result/output association",
              OCRProcessor.pendingRunIsSelfConsistent(completionState))
        completionState.completedOutputPaths = ["0": inDir.appendingPathComponent("escape.pdf").path]
        completionState.runFingerprint = OCRProcessor.pendingRunFingerprintV2(completionState)
        check("v2 structure rejects a completed output path outside the selected destination",
              !OCRProcessor.pendingRunIsSelfConsistent(completionState))

        let future = makeV2Run(files: files, config: runtimeConfig(schemaVersion: 99))
        check("unknown runtime schema fails closed even with a matching recomputed fingerprint",
              !OCRProcessor.pendingRunIsSelfConsistent(future))
        let misaligned = makeV2Run(files: files, config: runtimeConfig(boundaries: [true]))
        check("misaligned Live Capture parallel arrays fail closed",
              !OCRProcessor.pendingRunIsSelfConsistent(misaligned))
        let badScale = makeV2Run(files: files, config: runtimeConfig(imageScale: .infinity))
        check("non-finite/out-of-range runtime values fail closed",
              !OCRProcessor.pendingRunIsSelfConsistent(badScale))

        // W16.cfg5: resume constructs the same SessionProcessingConfig every downstream seam consumes.
        // Modern manifests overlay the persisted runtime snapshot; legacy run/batch records deliberately
        // use current defaults for fields their old schemas never captured.
        let resumeDefaultsSuite = "APBatchResume-\(UUID().uuidString)"
        let resumeDefaults = UserDefaults(suiteName: resumeDefaultsSuite)!
        defer { resumeDefaults.removePersistentDomain(forName: resumeDefaultsSuite) }
        resumeDefaults.set(TaggingMode.none.rawValue, forKey: DefaultsKeys.taggingModeRaw)
        resumeDefaults.set(RotationMode.llmMajority.rawValue, forKey: DefaultsKeys.rotationModeRaw)
        resumeDefaults.set(false, forKey: DefaultsKeys.mergeDocuments)
        resumeDefaults.set(42.0, forKey: DefaultsKeys.imageResolutionPercent)
        resumeDefaults.set(9.0, forKey: DefaultsKeys.standardImageSizeMB)
        resumeDefaults.set(6, forKey: DefaultsKeys.ocrWorkerCount)
        resumeDefaults.set(7.0, forKey: DefaultsKeys.pdfImageSizeMB)
        resumeDefaults.set(2, forKey: DefaultsKeys.textColumns)
        resumeDefaults.set(8.0, forKey: DefaultsKeys.exportedImageSizeMB)
        resumeDefaults.set(false, forKey: DefaultsKeys.outputImageFile)
        resumeDefaults.set("Live Default", forKey: DefaultsKeys.tagVocabulary)

        resumeDefaults.set(500.0, forKey: DefaultsKeys.imageResolutionPercent)
        let clampedHighLegacyRunConfig = processor.makePendingRunResumeConfig(
            run, apiKey: "legacy-key", defaults: resumeDefaults)
        resumeDefaults.set(0.0, forKey: DefaultsKeys.imageResolutionPercent)
        let clampedLowLegacyBatchConfig = processor.makePendingBatchResumeConfig(
            batch, apiKey: "batch-key", defaults: resumeDefaults)
        check("legacy resume configs retain the prior 1%...100% image-scale clamp",
              clampedHighLegacyRunConfig.imageScale == 1.0
              && clampedLowLegacyBatchConfig.imageScale == 0.01)
        resumeDefaults.set(42.0, forKey: DefaultsKeys.imageResolutionPercent)

        let resumedV2Config = processor.makePendingRunResumeConfig(
            v2, apiKey: "resume-key", defaults: resumeDefaults)
        check("v2 resume config restores persisted runtime values over contradictory current defaults",
              resumedV2Config.provider == v2.provider
              && resumedV2Config.model == v2.model
              && resumedV2Config.apiKey == "resume-key"
              && resumedV2Config.outputDirectory == outDir
              && resumedV2Config.taggingMode == .copySource
              && resumedV2Config.rotationMode == .off
              && resumedV2Config.mergeDocuments
              && !resumedV2Config.outputImageFile
              && resumedV2Config.imageScale == 0.37
              && resumedV2Config.standardImageMB == 4.5
              && resumedV2Config.ocrWorkerCount == 2
              && resumedV2Config.pdfImageMB == 1.5
              && resumedV2Config.textColumns == 3
              && resumedV2Config.exportedImageMB == 2.5)

        let legacyRunConfig = processor.makePendingRunResumeConfig(
            run, apiKey: "legacy-key", defaults: resumeDefaults)
        check("legacy PendingRun resume config uses current normalized defaults plus persisted identity",
              legacyRunConfig.provider == run.provider
              && legacyRunConfig.model == run.model
              && legacyRunConfig.apiKey == "legacy-key"
              && legacyRunConfig.outputDirectory == outDir
              && legacyRunConfig.taggingMode == .none
              && legacyRunConfig.rotationMode == .llmMajority
              && !legacyRunConfig.mergeDocuments
              && !legacyRunConfig.outputImageFile
              && legacyRunConfig.imageScale == 0.42
              && legacyRunConfig.standardImageMB == 9
              && legacyRunConfig.ocrWorkerCount == 6
              && legacyRunConfig.pdfImageMB == 7
              && legacyRunConfig.textColumns == 2
              && legacyRunConfig.exportedImageMB == 8)

        let legacyBatchConfig = processor.makePendingBatchResumeConfig(
            batch, apiKey: "batch-key", defaults: resumeDefaults)
        check("legacy PendingBatch resume config combines current defaults with persisted batch policy",
              legacyBatchConfig.provider == batch.provider
              && legacyBatchConfig.model == batch.model
              && legacyBatchConfig.apiKey == "batch-key"
              && legacyBatchConfig.outputDirectory == outDir
              && legacyBatchConfig.taggingMode == .automatic
              && legacyBatchConfig.outputImageFile
              && legacyBatchConfig.rotationMode == .llmMajority
              && legacyBatchConfig.standardImageMB == 9
              && legacyBatchConfig.ocrWorkerCount == 6
              && legacyBatchConfig.pdfImageMB == 7
              && legacyBatchConfig.textColumns == 2
              && legacyBatchConfig.exportedImageMB == 8)

        // Apply through the same method resumeRun uses, after deliberately setting contradictory live
        // values. cfg5 carries these values in the config instead of fanning them out.
        processor.taggingMode = .automatic
        processor.passSourceTags = false
        processor.rotationMode = .llmMajority
        processor.reviewRotation = false
        processor.mergeDocuments = false
        processor.tagVocabulary = []
        processor.exportOriginals = true
        processor.preGroupedBoundaries = []
        // W16.cfg6 deleted the six `nonisolated(unsafe)` statics this block used to snapshot and compare,
        // so "resume does not fan its settings out to process-globals" is now a *compile-time* property:
        // there is no longer anything to fan out to. What remains testable — and what the fan-out check
        // was really protecting — is that a SECOND processor is completely unaffected by the first one's
        // resume. Below, `bystander` shares nothing but the process.
        let bystander = OCRProcessor()
        processor.applyPendingRunRuntimeConfig(runtimeConfig())
        check("resume applies instance runtime settings instead of contradictory live UI values",
              processor.taggingMode == .copySource && processor.passSourceTags
              && processor.rotationMode == .off && processor.reviewRotation
              && processor.mergeDocuments && !processor.exportOriginals
              && processor.tagVocabulary == ["Correspondence", "Receipts"]
              && processor.preGroupedBoundaries == [true, false]
              && processor.preGroupedTypes.map(\.rawValue) == ["box", "document"])
        check("W16.cfg6: a resume leaks none of its runtime settings to a concurrent processor",
              bystander.activeRunConfig == nil
              && bystander.rotationMode == .llmSingle
              && bystander.taggingMode == .automatic
              && !bystander.passSourceTags && !bystander.reviewRotation
              && !bystander.mergeDocuments && bystander.tagVocabulary.isEmpty
              && bystander.preGroupedBoundaries.isEmpty && bystander.preGroupedTypes.isEmpty)
        let recaptured = processor.makePendingRunRuntimeConfig(
            imageScale: 0.37, gatewayConfig: nil, runConfig: resumedV2Config)
        check("run config recaptures every applied instance/injected setting into one immutable snapshot",
              recaptured.taggingMode == .copySource && recaptured.passSourceTags
              && recaptured.rotationMode == .off && recaptured.reviewRotation
              && recaptured.mergeDocuments && !recaptured.exportOriginals
              && recaptured.tagVocabulary == ["Correspondence", "Receipts"]
              && recaptured.preGroupedBoundaries == [true, false]
              && recaptured.preGroupedPriorities == ["P10", nil]
              && recaptured.imageScale == 0.37
              && recaptured.standardImageMB == 4.5 && recaptured.ocrWorkerCount == 2
              && recaptured.pdfImageMB == 1.5 && recaptured.textColumns == 3
              && recaptured.exportedImageMB == 2.5)
        check("legacy PendingRun remains readable and uses its legacy consistency path",
              loaded?.runtimeConfig == nil
              && (loaded.map { OCRProcessor.pendingRunIsSelfConsistent($0) } ?? false))

        // --- 11: B14 — paid multi-chunk lifecycle journal survives crashes without duplicate output. ---
        let lifecycleBatch = OCRProcessor.PendingBatch(
            batchId: "", provider: .gemini, model: LLMProvider.gemini.models[0],
            thinkingLevel: nil, fileURLs: files, outputDirectory: outDir, enableTagging: true,
            enableCollectionSegmentation: false, sendPreviousImage: false, submittedAt: Date(),
            enableSegmentJSON: true, confirmCollectionIDs: false, reviewDocumentSegmentation: false,
            customPrompt: nil, taggingMode: .automatic,
            runFingerprint: OCRProcessor.runFingerprint(
                files: files, outputDirectory: outDir, taggingMode: .automatic,
                enableTagging: true, batchMode: true, preserveInputOrder: true),
            exportOriginals: true,
            lifecycleVersion: OCRProcessor.PendingBatch.currentLifecycleVersion,
            submittedChunkIds: ["batches/chunk-a", "batches/chunk-b"],
            consumedChunkIds: ["batches/chunk-a"], submissionComplete: true,
            completedResults: ["0": done], completedOutputPaths: ["0": out0.path])
        let lifecycleURL = tmp.appendingPathComponent("pending_batch_v1.json")
        let writtenLifecycle = OCRProcessor._testWritePendingBatch(lifecycleBatch, to: lifecycleURL)
        let loadedLifecycle = OCRProcessor._testReadPendingBatch(from: lifecycleURL)
        check("paid-batch journal atomically persists all ordered chunk IDs",
              writtenLifecycle?.batchId == "batches/chunk-a,batches/chunk-b"
              && loadedLifecycle?.submittedChunkIds == ["batches/chunk-a", "batches/chunk-b"])
        check("paid-batch journal round-trips consumed chunks and per-file output associations",
              loadedLifecycle?.consumedChunkIds == ["batches/chunk-a"]
              && loadedLifecycle?.completedResults["0"]?.text == done.text
              && loadedLifecycle?.completedOutputPaths?["0"] == out0.path)
        check("round-tripped paid-batch lifecycle passes full evolving-state validation",
              loadedLifecycle.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false)
        if let loadedLifecycle {
            let reopened = OCRProcessor.batchByReopeningMissingOutputs(
                loadedLifecycle, fileExists: { $0 != out0.path })
            check("a missing completed PDF re-opens consumed chunks without losing server IDs",
                  reopened.completedResults.isEmpty
                  && reopened.completedOutputPaths?.isEmpty == true
                  && reopened.consumedChunkIds.isEmpty
                  && reopened.submittedChunkIds == loadedLifecycle.submittedChunkIds)
            let unchanged = OCRProcessor.batchByReopeningMissingOutputs(
                loadedLifecycle, fileExists: { _ in true })
            check("present completed PDFs retain their consumed/result journal state",
                  Set(unchanged.completedResults.keys) == Set(loadedLifecycle.completedResults.keys)
                  && unchanged.consumedChunkIds == loadedLifecycle.consumedChunkIds
                  && unchanged.lifecycleFingerprint == loadedLifecycle.lifecycleFingerprint)
        } else {
            check("missing-output recovery fixture is constructible", false)
            check("present-output recovery fixture is constructible", false)
        }

        var partialSubmission = lifecycleBatch
        partialSubmission.submittedChunkIds = ["batches/chunk-a"]
        partialSubmission.consumedChunkIds = []
        partialSubmission.submissionComplete = false
        partialSubmission.completedResults = [:]
        partialSubmission.completedOutputPaths = [:]
        let preparedPartial = OCRProcessor.preparedPendingBatchForPersistence(partialSubmission)
        check("a crash after the first multi-chunk create keeps that acknowledged job resumable",
              preparedPartial?.batchId == "batches/chunk-a"
              && (preparedPartial.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false))

        if var unknownChunk = loadedLifecycle {
            unknownChunk.consumedChunkIds.append("batches/not-submitted")
            let resigned = OCRProcessor.preparedPendingBatchForPersistence(unknownChunk)
            check("journal rejects a consumed chunk that was never submitted even after re-signing",
                  resigned != nil && !OCRProcessor.pendingBatchIsSelfConsistent(resigned!))
        } else {
            check("unknown-consumed-chunk fixture is constructible", false)
        }
        if var escapedOutput = loadedLifecycle {
            escapedOutput.completedOutputPaths?["0"] = inDir.appendingPathComponent("escape.pdf").path
            let resigned = OCRProcessor.preparedPendingBatchForPersistence(escapedOutput)
            check("journal rejects a completed batch output outside the selected destination",
                  resigned != nil && !OCRProcessor.pendingBatchIsSelfConsistent(resigned!))
        } else {
            check("escaped batch-output fixture is constructible", false)
        }
        if let lifecycleData = loadedLifecycle.flatMap({ try? JSONEncoder().encode($0) }),
           var legacyObject = try? JSONSerialization.jsonObject(with: lifecycleData) as? [String: Any] {
            for key in ["lifecycleVersion", "submittedChunkIds", "consumedChunkIds",
                        "submissionComplete", "completedResults", "completedOutputPaths",
                        "lifecycleFingerprint"] {
                legacyObject.removeValue(forKey: key)
            }
            let legacyData = try? JSONSerialization.data(withJSONObject: legacyObject)
            let decodedLegacy = legacyData.flatMap {
                try? JSONDecoder().decode(OCRProcessor.PendingBatch.self, from: $0)
            }
            check("pre-journal comma-separated paid batches remain readable and resumable",
                  decodedLegacy?.lifecycleVersion == nil
                  && decodedLegacy?.effectiveChunkIds == ["batches/chunk-a", "batches/chunk-b"]
                  && (decodedLegacy.map { OCRProcessor.pendingBatchIsSelfConsistent($0) } ?? false))
        } else {
            check("legacy paid-batch journal fixture is constructible", false)
        }

        // --- 12: provider response-shape contract for the three paid batch clients (W16.bat1). ---
        // Pure-parse, no network, no keys, no cost — literal Anthropic/Gemini/Mistral bodies through the
        // parse seams in `BatchOCR.swift`. Lives in its own file because it shares nothing with the
        // manifest fixtures above; it rides this driver so one script covers the whole paid-batch surface.
        BatchParseContract.run(check: check)

        // --- 13: the cancel path's journal-retention contract (W16.bat2). ---
        // The paid-batch recovery journal is deleted only when every chunk's server-side cancellation
        // was confirmed. Driven through the real `performServerBatchCancellation` seam with a stub
        // canceller and a real temp file, so "kept" means a file that is still on disk — no network,
        // no keys, no cost.
        await BatchCancelContract.run(check: check)

        // --- 14: the cancel path's WIRING contract (W16.bat2-fu). ---
        // Section 13 pins the rule; this pins the arguments `cancel()` feeds it — which paid jobs, which
        // provider's client, which durable journal, and whether the operator is warned. Drives the REAL
        // `cancel()` with both cancel-path seams stubbed, so the operator's own `pending_batch.json` is
        // never touched: no network, no keys, no cost.
        await BatchCancelWiringContract.run(check: check)

        // --- 15: the interrupted-batch TAIL contract (W16.bat4). ---
        // Sections 13/14 are about Stop; this one is about the run ending itself. Drives the real
        // `finishInterruptedBatchPoll()` — the single tail both paid-batch entry points run when a poll is
        // cut short with a server-side job possibly still alive — and pins that it recomputes the resume
        // banner (the Resume control every interruption message names), deletes exactly this run's own temp
        // conversions and nothing else in the directory, and leaves the interruption message, the run's
        // results and the interrupted-RUN manifest alone. No network, no keys, no cost. Temp files only,
        // except for one section (W16.bat4-fu) that writes a real journal at the shipped path so "the banners
        // are a fresh read" is a comparison of two non-empty strings rather than of two nils — hence the same
        // redirect verdict, and it restores both files byte for byte on the way out.
        BatchInterruptTailContract.run(check: check, redirected: journalsAreRedirected)

        // --- 16: where the journals resolve, and what the SHIPPED deleter does (W16.bat2-fu2). ---
        // Sections 13–15 all replace the deleter seam, so the default body — the line that actually removes
        // the operator's `pending_batch.json` — was verified by reading it. With the directory redirectable
        // (and gated twice, so production cannot be redirected by accident), this runs the real thing
        // against a real journal in the harness's own temp dir, and pins the fail-closed direction against
        // every bad reading of the two variables. No network, no keys, no cost. `journalsAreRedirected` was
        // decided at the top of this function, before section 13 pressed anything.
        await BatchJournalPathContract.run(check: check, redirected: journalsAreRedirected)

        // --- 17: what Stop during a paid batch POLL does to the journal (W16.bat3). ---
        // Sections 13/14/16 all stop at `cancel()`; this one follows the cancellation into the poll that is
        // unwinding at the same time, which is where the journal was actually being deleted. Drives the real
        // `pollBatchUntilComplete` and the real `resumeBatch` under a cancelled task — both cancellation
        // guards sit before any provider call, so no request is made: no network, no keys, no cost. Its last
        // two checks write a real journal at the shipped path, so they use the same redirect verdict.
        await BatchPollCancelContract.run(check: check, redirected: journalsAreRedirected)

        // --- 18: no paid-batch journal mutation fails in silence (W16.bat3-fu). ---
        // Section 17 covers the poll's two cancellation exits; this one is a layer down, at the three
        // mutators every paid-batch run advances its journal through. `performBatchOCR`'s FIFTH interrupted
        // exit guards on one of them, and its missing-journal failure — the shape a Stop mid-submit lands in
        // — used to return `false` without setting the flag both callers judge the run by. No provider call
        // is made and no journal is written outside section 2/3, which use the same redirect verdict.
        BatchMutationReportContract.run(check: check, redirected: journalsAreRedirected)

        // --- 19: what the interrupted submission tells the operator (W16.bat3-fu2). ---
        // Section 18 stops at "it said something." This is the sentence itself — the one an operator decides
        // whether to pay for the same pages again from. Its last section drives the real exit against a real
        // journal at the shipped path, so it uses the same redirect verdict and removes what it wrote.
        BatchSubmissionMessageContract.run(check: check, redirected: journalsAreRedirected)

        let passed = results.allSatisfy { $0.hasPrefix("PASS") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let outPath = ProcessInfo.processInfo.environment["BATCHRESUME_TEST_OUT"]
            ?? fm.temporaryDirectory.appendingPathComponent("APBatchResume-RESULT.txt").path
        try? report.write(toFile: outPath, atomically: true, encoding: .utf8)
        try? fm.removeItem(at: tmp)
        NSLog("BATCHRESUME DONE: \(passed ? "ALL PASS" : "SOME FAILED") → \(outPath)")
    }
}
