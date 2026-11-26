#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import Foundation
import AppKit
import PDFKit
import ArchiveCore

// Tests 13-20 of LiveCaptureRecoveryTestDriver.run(), one function each (W49.proc-build-memory).
extension LiveCaptureRecoveryTestDriver {
    /// Test 13 (W3.cap-r6) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest13(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        func makeConfig(_ out: URL) -> SessionProcessingConfig {
            SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
                outputDirectory: out,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1)
        }
        func stagedSeg(_ gid: String, pdf: URL) -> LiveCaptureProcessor.StagedSegment {
            let document = PDFDocument()
            document.insert(PDFPage(), at: 0)
            let identity = CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID())
            let catalogue = ProcessorCatalogueRecord(
                identity: identity, sourcePages: [.init(roles: ["image"])],
                document: .init(id: UUID(), ownerFileID: identity.fileID, fields: .init()), fileFields: .init())
            try? PDFGenerator.writeArchival(document, to: pdf, catalogueIdentity: identity)
            return LiveCaptureProcessor.StagedSegment(
                groupId: gid, type: CaptureGroupType.document.rawValue, collectionKey: gid, order: 0,
                pdfURLs: [pdf], imageURLs: [], jsonURL: nil, boxLabelText: nil, pagesComplete: true,
                catalogueRecords: (try? catalogue.encoded()).map { [$0] })
        }
        // `chosenExisting` is set on purpose: it makes the destination an explicit scratch folder, so
        // `currentOutputDirectory` (which would otherwise fall back to the operator's real Settings
        // output folder) can never contribute a path to this test.
        func draft(_ key: String, into folder: URL) -> LiveCaptureProcessor.CollectionDraft {
            LiveCaptureProcessor.CollectionDraft(
                id: key, finalName: folder.lastPathComponent, existingFolders: [], suggestedFolders: [],
                chosenExisting: folder, segmentCount: 1, photoCount: 1)
        }
        func manifestGroupIds(_ dir: URL) -> [String] {
            let u = dir.appendingPathComponent("staging-manifest.json")
            guard let d = try? Data(contentsOf: u),
                  let m = try? JSONDecoder().decode(ManifestPeek.self, from: d) else { return [] }
            return m.staged.map(\.groupId)
        }
        func settle(_ p: LiveCaptureProcessor) async {
            for _ in 0..<400 {
                if !p.isFinalizing { return }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
        // One session for both scenarios: `LiveCaptureProcessor` holds it `unowned`, and finalize only
        // uses it for `clearFiled` — which retires nothing here, because no `retained` sources exist.
        let r6Session = CaptureSession()
        // Distinctively NAMED staging dirs (not `_processed`) so the reclaim case can take its own
        // folder back out of the Trash instead of leaving one behind on every Tier-2 run.
        let tok = String(UUID().uuidString.prefix(8))

        // (b) THE BUG: a straggler finalizes during the move.
        let keepDir = tmp.appendingPathComponent("APStaging-keep-\(tok)", isDirectory: true)
        try? fm.createDirectory(at: keepDir, withIntermediateDirectories: true)
        let plannedPDF = keepDir.appendingPathComponent("planned.pdf")
        let keepOut = tmp.appendingPathComponent("r6keep", isDirectory: true)
        let keepProc = LiveCaptureProcessor(session: r6Session)
        keepProc._recoveryTestArm(stagingDir: keepDir, config: makeConfig(keepOut),
                                  staged: [stagedSeg("planned", pdf: plannedPDF)])
        keepProc.finalize([draft("planned", into: keepOut)])
        // Still the SAME MainActor turn: `finalize` has already snapshotted `plans` and enqueued its
        // Task, but that Task cannot have run. Writing output into the staging dir and appending to
        // `staged` here reproduces the straggler's interleaving exactly, and deterministically.
        let stragglerPDF = keepDir.appendingPathComponent("straggler.pdf")
        keepProc._recoveryTestAppendStaged(stagedSeg("straggler", pdf: stragglerPDF))
        await settle(keepProc)
        check("a straggler that finalized during the move KEEPS the staging directory",
              fm.fileExists(atPath: keepDir.path))
        check("...and its processed output is still on disk, not in the Trash",
              fm.fileExists(atPath: stragglerPDF.path))
        check("...and it is still staged, so Finish again can file it",
              keepProc.staged.map(\.groupId) == ["straggler"])
        check("...and the reduced manifest on disk lists exactly the straggler",
              manifestGroupIds(keepDir) == ["straggler"])
        check("...while the PLANNED segment really did file (the fix costs nothing)",
              !fm.fileExists(atPath: plannedPDF.path)
                  && fm.fileExists(atPath: keepOut.appendingPathComponent("000001 r6keep.pdf").path)
                  && fm.fileExists(atPath: keepOut.appendingPathComponent("000001 r6keep.pdf.archivesuite.json").path))
        check("...and the operator is TOLD, instead of seeing a clean \"Finalized\"",
              keepProc.finalizeSummary?.contains("finished processing while this batch was being filed") == true)

        // (c) The happy path must still reclaim: nothing arrives behind the move, so the spent staging
        // dir goes to the Trash exactly as before.
        let goneDir = tmp.appendingPathComponent("APStaging-reclaim-\(tok)", isDirectory: true)
        try? fm.createDirectory(at: goneDir, withIntermediateDirectories: true)
        let onlyPDF = goneDir.appendingPathComponent("only.pdf")
        let goneOut = tmp.appendingPathComponent("r6gone", isDirectory: true)
        let goneProc = LiveCaptureProcessor(session: r6Session)
        goneProc._recoveryTestArm(stagingDir: goneDir, config: makeConfig(goneOut),
                                  staged: [stagedSeg("only", pdf: onlyPDF)])
        goneProc.finalize([draft("only", into: goneOut)])
        await settle(goneProc)
        check("no straggler → the spent staging directory is still reclaimed (regression)",
              !fm.fileExists(atPath: goneDir.path) && goneProc.staged.isEmpty)
        check("...and the summary carries no straggler warning",
              goneProc.finalizeSummary?.contains("finished processing while") != true)

        let retryDir = tmp.appendingPathComponent("APStaging-pair-retry-\(tok)", isDirectory: true)
        let retryOut = tmp.appendingPathComponent("r6pair", isDirectory: true)
        try? fm.createDirectory(at: retryDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: retryOut, withIntermediateDirectories: true)
        let workingPDF = retryDir.appendingPathComponent("retry.pdf")
        let finalPDF = retryOut.appendingPathComponent("000001 r6pair.pdf")
        let finalCompanion = finalPDF.appendingPathExtension("archivesuite.json")
        let retryProc = LiveCaptureProcessor(session: r6Session)
        let optionalJSON = retryDir.appendingPathComponent("retry.json")
        try? Data("optional export".utf8).write(to: optionalJSON)
        var pendingSegment = stagedSeg("retry-pair", pdf: workingPDF)
        pendingSegment.jsonURL = optionalJSON
        retryProc._recoveryTestArm(stagingDir: retryDir, config: makeConfig(retryOut),
                                   staged: [pendingSegment])
        let before = try? Data(contentsOf: workingPDF)
        retryProc.finalize([draft("retry-pair", into: retryOut)])
        let foreign = Data("outside file must survive".utf8)
        try? foreign.write(to: finalCompanion)
        await settle(retryProc)
        check("a companion-only collision keeps the staged PDF, its manifest and the occupying bytes",
              before != nil && (try? Data(contentsOf: workingPDF)) == before
                  && !fm.fileExists(atPath: finalPDF.path)
                  && (try? Data(contentsOf: finalCompanion)) == foreign
                  && manifestGroupIds(retryDir) == ["retry-pair"])
        try? fm.removeItem(at: finalCompanion)
        try? Data().write(to: retryOut.appendingPathComponent("000042 another.pdf"))
        let wrongJSONFolder = tmp.appendingPathComponent("not-an-export-destination", isDirectory: true)
        try? fm.createDirectory(at: wrongJSONFolder, withIntermediateDirectories: true)
        try? fm.createSymbolicLink(at: retryOut.appendingPathComponent("JSON Output"), withDestinationURL: wrongJSONFolder)
        retryProc.finalize([draft("retry-pair", into: retryOut)])
        await settle(retryProc)
        check("Finish retries the pinned number despite a newer PDF and publishes both members",
              before != nil && (try? Data(contentsOf: finalPDF)) == before
                  && (try? Data(contentsOf: finalCompanion)).flatMap { try? CatalogueRecord(json: $0) } != nil
                  && retryProc.staged.isEmpty)
        check("an aliased optional export folder leaves the staged JSON and does not touch that folder",
              (try? fm.contentsOfDirectory(atPath: wrongJSONFolder.path))?.isEmpty == true
                  && fm.fileExists(atPath: optionalJSON.path))

        // The reclaim above went to the Trash (recoverable, by design). Take our own probe folder back
        // out so a Tier-2 run doesn't leave one behind each time — best-effort, since the physical
        // Trash location varies with the app's launch context. The assertion is about the ORIGINAL
        // path being gone, so it does not depend on this succeeding.
        try? fm.removeItem(at: fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/\(goneDir.lastPathComponent)"))
    }

    /// Test 14 (W3.cap-r2) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest14(tmp: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let r2Out = tmp.appendingPathComponent("r2out", isDirectory: true)
        let r2Staging = tmp.appendingPathComponent("APStaging-r2-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: r2Staging, withIntermediateDirectories: true)
        let r2Session = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        r2Session._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .automatic, rotationMode: .off, mergeDocuments: false,
                outputDirectory: r2Out,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: r2Staging)
        let jpeg = Data("synthetic page bytes".utf8)
        func send(_ gid: String, _ seq: Int) -> Bool {
            r2Session.ingest(jpeg: jpeg, groupId: gid, seq: seq, type: .document,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone") != nil
        }
        func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }

        let firstAccepted = send("G1", 1)
        check("the page's first upload is accepted (so the retry checks aren't passing on nothing)",
              firstAccepted)
        check("...and it starts exactly one paid OCR call", paidStarts() == 1)

        let retryAccepted = send("G1", 1)   // THE BUG: the phone's auto-retry after a dropped ack
        check("the dropped-ack retry is accepted too (a real second trip through ingest)", retryAccepted)
        check("a re-upload of the SAME (groupId, seq) buys NO second paid OCR call", paidStarts() == 1)
        check("...and the session still holds exactly one photo for that page", r2Session.photos.count == 1)
        // Counting starts alone cannot catch a fix that de-duplicates but files the surviving Task under
        // a key nothing reads: ask the REPLACEMENT photo for its result, the way finalize asks. Without
        // this the page would finalize as "OCR not started" and be filed image-only.
        let replaced = r2Session.photos.first
        let carried = replaced == nil ? nil
            : await r2Session.liveProcessor._recoveryTestPageOCRText(for: replaced!)
        check("...and finalize still reaches the FIRST call's result through the replacement photo",
              carried == "stub page text")

        // The guard must not over-dedup — `(groupId, seq)` has to keep genuinely distinct pages distinct.
        check("a genuinely new page in the same group still starts its own OCR",
              send("G1", 2) && paidStarts() == 2)
        check("a page in a different group still starts its own OCR",
              send("G2", 3) && paidStarts() == 3)

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
    }

    /// Test 15 (W3.cap-r5) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest15(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let r5Out = tmp.appendingPathComponent("r5out", isDirectory: true)
        let r5Staging = tmp.appendingPathComponent("APStaging-r5-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: r5Staging, withIntermediateDirectories: true)
        let r5Session = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        r5Session._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human`, not `.automatic`: `computeTags` only reaches the LLM for a DOCUMENT in
                // automatic mode, and a box/folder short-circuits to a colour tag inside `TagGenerator`.
                // So this test finalizes real segments for $0 and never touches the network.
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: r5Out,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: r5Staging)
        let r5Proc = r5Session.liveProcessor
        let r5Bytes = Data("synthetic page bytes".utf8)
        func r5Send(_ gid: String, _ seq: Int, _ type: CaptureGroupType) {
            r5Session.ingest(jpeg: r5Bytes, groupId: gid, seq: seq, type: type,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        func r5Settle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func r5Key(_ gid: String) -> String? { r5Proc.staged.first { $0.groupId == gid }?.collectionKey }

        // The gate the in-flight document's OCR result parks on. Holding it is what makes the
        // interleaving deterministic — a sleep would only *hope* to land inside the window.
        let r5Gate = TestGate()

        // 1. The first Box, delivered in order: it opens collection "B0".
        r5Send("B0", 1, .box)
        _ = await r5Settle { r5Key("B0") != nil }

        // 2. The document (capture seq 3). It was shot after a second Box, but the relay delivers it
        //    first, so on arrival it is pinned to the only Box the Mac has seen — "B0". Its page OCR is
        //    held, so the finalize its tag card triggers parks mid-flight.
        LiveCaptureProcessor._recoveryTestOCRGate = { await r5Gate.wait() }
        r5Send("D", 3, .document)
        LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold THAT page only
        r5Proc.segmentResolved(groupId: "D")
        let parked = await r5Settle { r5Proc.isFinalized("D") }
        check("the document is genuinely mid-finalize when the Box lands (finalized, not yet staged)",
              parked && r5Key("D") == nil)

        // 3. THE BUG: the out-of-order Box (capture seq 2 — before the document) arrives NOW, inside
        //    the window. It is the document's correct collection.
        r5Send("B1", 2, .box)

        // 4. Release the held page and let the segment finish writing itself out.
        r5Gate.open()
        let landed = await r5Settle { r5Key("D") != nil }
        check("the in-flight document finishes staging", landed)
        check("an out-of-order Box delivered mid-finalize RE-PINS the in-flight document",
              r5Key("D") == "B1")
        check("...and the live map the rotation review regenerates from agrees",
              r5Proc._recoveryTestLiveCollectionKey(for: "D") == "B1")
        // The out-of-order Box's own finalize was only ENQUEUED by `ingest`; settle for it before asking
        // about its staged record (it reds ~1 run in 10 on a loaded machine otherwise — W3.cap-r4).
        _ = await r5Settle { r5Key("B1") != nil }
        check("a Box is still its own collection and is never re-pinned",
              r5Key("B0") == "B0" && r5Key("B1") == "B1")

        // 5. The correction is ordered, not "latest wins": a Box captured AFTER the document (seq 4)
        //    must not steal it away from B1.
        r5Send("B2", 4, .box)
        _ = await r5Settle { r5Key("B2") != nil }
        check("a Box captured AFTER the document does not steal it", r5Key("D") == "B1")

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRGate = nil
    }

    /// Test 16 (W3.cap-r4) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest16(tmp: URL, stubModel: LLMModel, isolatedBackup: Bool, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        let r4Out = tmp.appendingPathComponent("r4out", isDirectory: true)
        let r4Staging = tmp.appendingPathComponent("APStaging-r4-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: r4Staging, withIntermediateDirectories: true)
        // Isolation, and it is load-bearing: `CaptureSession.init` adopts the newest backup session that
        // still holds unprocessed photos (crash recovery). The tests above leave theirs behind, so
        // without this the session below inherits their groups — including BOXES, whose capture order
        // then decides where this test's document is pinned. That is the exact fact under test, and it
        // made the first draft of this test pass before it had done anything. Only session-named folders
        // under the throwaway root are removed (`isolatedBackup` is what proves it is the script's
        // mktemp dir and not the operator's Backup Folder), matched with the same conservative predicate
        // launch-time pruning uses.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let r4Session = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        r4Session._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: r4Out,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: r4Staging)
        let r4Proc = r4Session.liveProcessor
        let r4Bytes = Data("synthetic page bytes".utf8)
        func r4Send(_ gid: String, _ seq: Int, _ type: CaptureGroupType) {
            r4Session.ingest(jpeg: r4Bytes, groupId: gid, seq: seq, type: type,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        func r4Settle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func r4Key(_ gid: String) -> String? { r4Proc.staged.first { $0.groupId == gid }?.collectionKey }

        // 1. A Box, then the document (capture seq 3) — both in order, so it pins to the only Box seen.
        r4Send("B0", 1, .box)
        _ = await r4Settle { r4Key("B0") != nil }
        r4Send("D", 3, .document)
        r4Proc.segmentResolved(groupId: "D")
        let r4Staged = await r4Settle { r4Key("D") != nil }
        check("the document stages under the only Box the Mac has seen", r4Staged && r4Key("D") == "B0")

        // 2. The out-of-order Box (capture seq 2 — shot BEFORE the document) finally arrives. It is the
        //    document's real collection, and backfill corrects the already-staged record.
        r4Send("B1", 2, .box)
        check("an out-of-order Box corrects the already-staged document", r4Key("D") == "B1")
        // `ingest` back-fills synchronously (the check above is deterministic) but only ENQUEUES the
        // Box's own finalize. The draft assertion below reads `beginFinalize`'s grouping, which sees
        // only what has staged — so wait for the Box itself, or the last check turns into a load-
        // dependent flake that reds on a busy machine while the product invariant is fine.
        _ = await r4Settle { r4Key("B1") != nil }

        // 3. THE BUG: the operator straightens that page in the end-of-session rotation review. This is
        //    the review sheet's own path — it edits the page list, then applies.
        let r4Source = r4Session.photos.first { $0.groupId == "D" }?.url
        check("the staged document's source page is on disk for regeneration", r4Source != nil)
        if let r4Source {
            r4Proc.rotationReviewPages = [
                LiveCaptureProcessor.RotationReviewPage(groupId: "D", pageIndex: 0, order: 3,
                                                        sourceURL: r4Source, rotationDegrees: 90)
            ]
            r4Proc.applyRotationReviewAndFinalize()
            // Non-vacuity: `isFinalizing` is set synchronously ONLY when there is a segment to regenerate.
            // Without this the checks below could pass on a run that never re-wrote anything.
            check("the rotation change really does trigger a regeneration", r4Proc.isFinalizing)
            let r4Done = await r4Settle { !r4Proc.isFinalizing }
            check("...and the regeneration completes", r4Done)
            check("straightening a page does NOT re-file the document into the previous collection",
                  r4Key("D") == "B1")
            // What the operator actually sees next: the naming sheet groups by collection key. The
            // misfile shows up here as the document sitting in the wrong draft.
            let b1 = r4Proc.drafts.first { $0.id == "B1" }
            let b0 = r4Proc.drafts.first { $0.id == "B0" }
            check("...so the naming sheet offers the document with its own Box, not the previous one",
                  b1?.segmentCount == 2 && b0?.segmentCount == 1)
        }

        LiveCaptureProcessor._recoveryTestOCRStub = nil
    }

    /// Test 17 (W3.cap-r3) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest17(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // Same isolation as Test 16, and load-bearing for the same reason: `CaptureSession.init` adopts
        // the newest backup session that still holds unprocessed photos, and the tests above leave theirs
        // behind. Inheriting their photos would put pages in this session that it never ingested — and
        // `paidStarts()` counts starts for the whole run, so the counts below would read someone else's.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let r3Out = tmp.appendingPathComponent("r3out", isDirectory: true)
        let r3Staging = tmp.appendingPathComponent("APStaging-r3-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: r3Staging, withIntermediateDirectories: true)
        let r3Session = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        r3Session._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — see Test 15: a document only reaches the LLM in `.automatic`, so the
                // mid-finalize case below finalizes for real, for $0, with no network.
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: r3Out,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: r3Staging)
        let r3Proc = r3Session.liveProcessor
        let r3Bytes = Data("synthetic page bytes".utf8)
        // The gate keeps every page this test ingests parked mid-OCR. A finished Task cannot be shown to
        // have been cancelled, so an un-gated page would make every assertion below vacuous.
        let r3Gate = TestGate()
        LiveCaptureProcessor._recoveryTestOCRGate = { await r3Gate.wait() }
        func r3Send(_ gid: String, _ seq: Int) {
            r3Session.ingest(jpeg: r3Bytes, groupId: gid, seq: seq, type: .document,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        func r3Settle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
        func photo(_ gid: String, _ seq: Int) -> CapturedPhoto? {
            r3Session.photos.first { $0.groupId == gid && $0.seq == seq }
        }
        func cancelled(_ p: CapturedPhoto) -> Bool {
            LiveCaptureProcessor._recoveryTestOCRTasks[LiveCaptureProcessor.PageKey(p)]?.isCancelled ?? false
        }

        // 1. THE BUG: the operator deletes a page in the Captured pane while its OCR is still in flight.
        r3Send("R1", 1)
        let p1 = photo("R1", 1)
        check("the deleted-mid-OCR page was really ingested and bought a call",
              p1 != nil && paidStarts() == 1)
        if let p1 {
            // Non-vacuity: the call must be LIVE and reachable at the moment of the delete, or "cancelled
            // + gone" afterwards would be true of a page that had simply already finished.
            check("...its call is in flight, uncancelled, and held in pageTasks before the delete",
                  !cancelled(p1) && r3Proc._recoveryTestHasPageTask(for: p1))

            r3Session.removePhoto(p1)

            check("deleting the page CANCELS its paid OCR call", cancelled(p1))
            check("...and drops its Task out of pageTasks (nothing orphaned)",
                  !r3Proc._recoveryTestHasPageTask(for: p1))
            check("...and the page really did leave the session", photo("R1", 1) == nil)
            // The started-once guard (W3.cap-r2) has to be retired WITH the task: this page has no OCR
            // any more, so if the phone re-sends it, it must be free to buy a new call. Leaving the guard
            // armed over an absent task would file the page as "OCR not started" instead — silently
            // text-less. This is also the behavioural read of the started-once guard, which is private
            // (`pageTasks`, since W3.cap-r3-fu1 retired the second copy that used to shadow it).
            r3Send("R1", 1)
            check("...so a later arrival of that same page is free to buy its own call",
                  photo("R1", 1) != nil && paidStarts() == 2)
        }

        // 2. The cancel is scoped to the ONE page. A fix that cancelled the group (or the session) would
        //    silently throw away the sibling pages the operator is still capturing.
        r3Send("R2", 1)
        r3Send("R2", 2)
        let s1 = photo("R2", 1), s2 = photo("R2", 2)
        check("a two-page group has both pages in flight", s1 != nil && s2 != nil && paidStarts() == 4)
        if let s1, let s2 {
            r3Session.removePhoto(s1)
            check("deleting one page of a group cancels exactly that page", cancelled(s1))
            check("...and leaves its sibling's call running and reachable",
                  !cancelled(s2) && r3Proc._recoveryTestHasPageTask(for: s2))
        }

        // 3. The reclassify path (`X-Replaces`): the phone moved a page into another group, so the Mac
        //    tombstones the old copy. The OCR bought for that old copy is money nobody will read either.
        r3Send("R3", 7)
        let t1 = photo("R3", 7)
        check("the reclassified page's old copy is in flight", t1 != nil && paidStarts() == 5)
        if let t1 {
            r3Session.removePhotoIfSafe(groupId: "R3", seq: 7)
            check("tombstoning a reclassified page's old copy cancels its OCR too", cancelled(t1))
            check("...and orphans nothing in pageTasks", !r3Proc._recoveryTestHasPageTask(for: t1))
            check("...and the old copy is gone from the session", photo("R3", 7) == nil)
        }

        // 4. The deliberate carve-out, and the reason this fix is a guard rather than an unconditional
        //    cancel: while the segment is MID-FINALIZE, finalize is the task's consumer. It snapshotted
        //    the group before its awaits and is about to read this page's result into the segment's text,
        //    so the call is already bought — cancelling there would discard paid output instead of saving
        //    any. Without this check, "cancel unconditionally" passes every assertion above.
        r3Send("R4", 1)
        let f1 = photo("R4", 1)
        r3Proc.segmentResolved(groupId: "R4")
        let parked = await r3Settle { r3Proc.isFinalized("R4") }
        check("the segment is genuinely mid-finalize (finalized, not yet staged)",
              parked && f1 != nil && r3Proc.retainedText(for: "R4") == nil)
        if let f1 {
            r3Session.removePhoto(f1)
            check("a page removed MID-FINALIZE is not cancelled", !cancelled(f1))
            check("...and its Task stays in pageTasks for finalize to read",
                  r3Proc._recoveryTestHasPageTask(for: f1))
            r3Gate.open()   // release every parked page; finalize can now finish
            let consumed = await r3Settle { r3Proc.retainedText(for: "R4") != nil }
            check("...and finalize really does consume the result it was left",
                  consumed && r3Proc.retainedText(for: "R4") == "stub page text")
        }

        // 5. The same carve-out, measured on the OUTPUT rather than on the mechanism. Scenario 4 can only
        //    assert the Task's state: finalize had already read that one page's Task out of `pageTasks`
        //    before it suspended, so removing the entry afterwards costs it nothing, and the test gate is
        //    cancellation-blind by design (Test 15 needs it to park, not to throw). Here the removed page
        //    is the SECOND of two, and finalize is parked on the FIRST — so its entry has not been read
        //    yet and an unconditional cancel really does lose it. The segment's retained text is then
        //    short by a page: the operator paid for two pages of OCR and the record keeps one. That is
        //    the consequence the guard exists to prevent, and it is what makes this more than a
        //    restatement of the implementation.
        let gate5 = TestGate()
        LiveCaptureProcessor._recoveryTestOCRGate = { await gate5.wait() }
        r3Send("R5", 1)
        r3Send("R5", 2)
        LiveCaptureProcessor._recoveryTestOCRGate = nil
        let g2 = photo("R5", 2)
        r3Proc.segmentResolved(groupId: "R5")
        let parked5 = await r3Settle { r3Proc.isFinalized("R5") }
        check("a two-page segment is mid-finalize, parked on its FIRST page",
              parked5 && g2 != nil && r3Proc.retainedText(for: "R5") == nil)
        if let g2 {
            r3Session.removePhoto(g2)
            gate5.open()
            let done5 = await r3Settle { r3Proc.retainedText(for: "R5") != nil }
            let pages = (r3Proc.retainedText(for: "R5") ?? "").components(separatedBy: "stub page text").count - 1
            check("deleting the not-yet-read page mid-finalize does NOT drop the OCR it already paid for",
                  done5 && pages == 2)
        }

        // 6. The IDENTITY the delete resolves — found by the adversarial pass over the fix above, and the
        //    one way this fix could have made things worse than the bug it closes. `CapturedPhoto.id` is
        //    a fresh UUID minted per VALUE (and `==` compares only `id`), while an idempotent re-upload —
        //    the phone resuming after a dropped ack — replaces the value in `photos` under the SAME
        //    `(groupId, seq)` with a NEW id. A SwiftUI row closure rendered before that replace therefore
        //    hands the delete a photo whose `id` is gone. The cancel keys on `(groupId, seq)`; the
        //    removal used to key on `id`. In that window the two disagreed: the cancel killed the LIVE
        //    page's call and `removeAll` removed nothing, so a page stayed in the session with no task
        //    and its source in the Trash — which finalize files as "OCR not started" over a placeholder
        //    image, i.e. a silently text-less archival document. Pre-fix that same window trashed the
        //    file but left the OCR running, so the text survived; keying the two halves differently is
        //    what widened the harm.
        let gate6 = TestGate()
        LiveCaptureProcessor._recoveryTestOCRGate = { await gate6.wait() }
        r3Send("R6", 1)
        r3Send("R6", 2)
        let stale2 = photo("R6", 2)     // the value a row closure captured…
        r3Send("R6", 2)                 // …then the phone re-uploads that page: same key, NEW value/id
        let live2 = photo("R6", 2)
        check("an idempotent re-upload replaces the page's value under the same key, with a new id",
              stale2 != nil && live2 != nil && stale2?.id != live2?.id
                  && stale2?.groupId == live2?.groupId && stale2?.seq == live2?.seq)
        if let stale2, let live2 {
            // Non-vacuity: the live page's call has to be in flight and reachable here, or the
            // "left behind with its call cancelled" invariant below could not distinguish anything.
            check("...and the live page's call is in flight and reachable before the delete",
                  !cancelled(live2) && r3Proc._recoveryTestHasPageTask(for: live2))
            r3Session.removePhoto(stale2)   // the operator's ✕, holding the pre-replace value
            check("deleting through a stale value still removes the page it names", photo("R6", 2) == nil)
            // The harm, stated as an invariant over what is LEFT rather than over the mechanism: no page
            // may remain in the session with its paid call cancelled, its Task gone, or its source
            // trashed under it. Pre-fix, page 2 is still listed and fails all three.
            let orphaned = r3Session.photos.filter { $0.groupId == "R6" }.filter {
                cancelled($0) || !r3Proc._recoveryTestHasPageTask(for: $0)
                    || !fm.fileExists(atPath: $0.url.path)
            }
            check("...leaving no page in the session whose call was cancelled or whose source was trashed",
                  orphaned.isEmpty)
            check("...and the sibling page it did not name is untouched",
                  photo("R6", 1).map { !cancelled($0) && r3Proc._recoveryTestHasPageTask(for: $0) } == true)
            gate6.open()   // release R6's parked pages; nothing after this ingests
        }

        // 7. W3.cap-r3-fu3: operator deletion must refuse a page whose segment is staged (or staging).
        // Keep this in the same isolated session so both the JPEG and staging output stay under `tmp`.
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRGate = nil
        r3Send("R7", 1)
        let stagedPhoto = photo("R7", 1)
        r3Proc.segmentResolved(groupId: "R7")
        let staged = await r3Settle { r3Proc.staged.contains { $0.groupId == "R7" } }
        check("the refusal fixture has a fully staged segment", staged && stagedPhoto != nil)
        if let stagedPhoto {
            let sourceBefore = try? Data(contentsOf: stagedPhoto.url)
            r3Session.removePhoto(stagedPhoto)
            check("✕ refuses to remove a page from its staged segment",
                  photo("R7", 1) != nil && r3Proc.isFinalized("R7"))
            check("...and preserves the source photo on disk",
                  sourceBefore != nil && (try? Data(contentsOf: stagedPhoto.url)) == sourceBefore)
            check("...and tells the operator to retry/re-stage before removing a page",
                  r3Session.statusMessage.localizedCaseInsensitiveContains("already staged")
                      && r3Session.statusMessage.localizedCaseInsensitiveContains("retry/re-stage"))
        }

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        LiveCaptureProcessor._recoveryTestOCRGate = nil
    }

    /// Test 17 (W3.cap-r3-fu1) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest17fu1(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // Same isolation as Tests 16/17, load-bearing for the same reason: `CaptureSession.init` adopts
        // the newest backup session that still holds unprocessed photos, and every test above leaves
        // theirs behind. Inherited photos would put pages in this session it never ingested, and
        // `paidStarts()` counts starts for the whole run.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let fuOut = tmp.appendingPathComponent("fu1out", isDirectory: true)
        let fuStaging = tmp.appendingPathComponent("APStaging-fu1-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: fuStaging, withIntermediateDirectories: true)
        let fuSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        fuSession._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — a document only reaches the LLM in `.automatic`, so every finalize below
                // runs for real, for $0, with no network.
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: fuOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: fuStaging)
        let fuProc = fuSession.liveProcessor
        let fuBytes = Data("synthetic page bytes".utf8)
        func fuSend(_ gid: String, _ seq: Int) {
            fuSession.ingest(jpeg: fuBytes, groupId: gid, seq: seq, type: .document,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        func fuSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
        func fuPhoto(_ gid: String, _ seq: Int) -> CapturedPhoto? {
            fuSession.photos.first { $0.groupId == gid && $0.seq == seq }
        }
        func textPages(_ gid: String) -> Int {
            (fuProc.retainedText(for: gid) ?? "").components(separatedBy: "stub page text").count - 1
        }
        func lateWarned() -> Bool { fuSession.statusMessage.contains("late page arrived") }

        // 1. The page is re-sent while its document is STAGED but not yet filed. The app has a message for
        //    exactly this ("a late page arrived… kept in the Backup Folder"), and the stale guard made it
        //    unreachable for the only pages that can reach that state: the page vanished into a `return`.
        fuSend("F1", 1)
        fuProc.segmentResolved(groupId: "F1")
        let f1Staged = await fuSettle { fuProc.staged.contains { $0.groupId == "F1" } }
        check("the document staged, so the re-send below is a genuine late arrival",
              f1Staged && paidStarts() == 1 && fuProc.isFinalized("F1") && !lateWarned())
        fuSend("F1", 1)
        check("a page re-sent for an already-staged document TELLS the operator instead of vanishing",
              lateWarned())
        check("...and buys nothing — it cannot join a document that is already written",
              paidStarts() == 1)

        // 2. W3.cap-r3-fu4: once Finish confirms the output in its destination, the group stays closed
        //    after `finalize` releases its transient staged marker. A dropped-ack retry and a genuinely
        //    new page both remain visible in the Backup Folder without starting a second document.
        let f1Key = fuProc.staged.first { $0.groupId == "F1" }?.collectionKey ?? "__unfiled__"
        fuProc.finalize([LiveCaptureProcessor.CollectionDraft(
            id: f1Key, finalName: fuOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
            chosenExisting: fuOut, segmentCount: 1, photoCount: 1)])
        let filed = await fuSettle { !fuProc.isFinalizing && fuProc.staged.isEmpty }
        check("the document really filed, so what follows is the post-filing state and not a partial",
              filed && !fuProc.isFinalized("F1"))
        let filedGroupRecorded = fuSession.filedGroupIds.contains("F1")
        fuSend("F1", 1)   // the phone's dropped-ack re-upload, arriving after Finish
        let filedRetryRefused = paidStarts() == 1 && lateWarned()
            && fuPhoto("F1", 1) != nil && fuProc.staged.isEmpty
        fuSend("F1", 2)   // a new page still cannot reopen a group filed earlier this session
        check("W3.cap-r3-fu4: a filed group's retry and new page stay backed up with no second OCR/doc",
              filedGroupRecorded && filedRetryRefused && paidStarts() == 1
                  && lateWarned() && fuPhoto("F1", 2) != nil && fuProc.staged.isEmpty)

        // 3. The trap this fix had to avoid, and the reason it is keyed on the Task rather than retired in
        //    the carve-out: a page removed MID-FINALIZE keeps the Task finalize is suspended on, so it
        //    must keep the guard too. Retiring the key there would let the phone's re-send overwrite that
        //    entry — buying the page a second time and handing finalize a different call's result — and
        //    would tell the operator a "late page arrived" for a page that IS being included. Both guards
        //    now cover the window (no Task is free, and the group is in `finalizedGroups`); these checks
        //    pin the OUTCOME, which is what a future edit to either one must not change.
        // W3.cap-r6 reclaimed F1's now-spent staging folder; restore the scratch folder so the unrelated
        // F2/F3 in-flight cases below can stage normally.
        try? fm.createDirectory(at: fuStaging, withIntermediateDirectories: true)
        let fuGate = TestGate()
        LiveCaptureProcessor._recoveryTestOCRGate = { await fuGate.wait() }
        fuSend("F2", 1)
        fuSend("F2", 2)
        LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold only F2's two pages
        let f2p2 = fuPhoto("F2", 2)
        fuProc.segmentResolved(groupId: "F2")
        let parked = await fuSettle { fuProc.isFinalized("F2") }
        check("a two-page segment is mid-finalize, parked on its FIRST page",
              parked && f2p2 != nil && paidStarts() == 3 && fuProc.retainedText(for: "F2") == nil)
        if let f2p2 {
            fuSession.removePhoto(f2p2)   // carve-out: not cancelled, its Task kept for finalize to read
            fuSend("F2", 2)               // the phone re-sends it INSIDE that window
            check("a page re-sent while finalize is suspended on its group buys NO second call",
                  paidStarts() == 3)
            check("...and is not mislabelled a late arrival — its call is the one being read",
                  !lateWarned())
            fuGate.open()
            let consumed = await fuSettle { fuProc.retainedText(for: "F2") != nil }
            check("...and finalize still reads both pages of OCR the operator paid for",
                  consumed && textPages("F2") == 2)
        }

        // 4. The other end of the same duplication, and the reason the fix DELETED the second record
        //    rather than kept it in sync: the reclaim branch of `finalize` used to empty that set
        //    WHOLESALE when a batch filed cleanly. Reclaim needs nothing left staged — not nothing left
        //    RUNNING — so a page still mid-OCR in a group this batch never planned was disarmed along
        //    with the filed ones, and the phone's dropped-ack re-upload of it could buy its call a second
        //    time. `pageTasks` cannot be emptied that way: the entry is the call.
        let fuGate4 = TestGate()
        LiveCaptureProcessor._recoveryTestOCRGate = { await fuGate4.wait() }
        fuSend("F3", 1)                                   // still mid-OCR, and never planned below
        LiveCaptureProcessor._recoveryTestOCRGate = nil
        let f2Key = fuProc.staged.first { $0.groupId == "F2" }?.collectionKey ?? "__unfiled__"
        fuProc.finalize([LiveCaptureProcessor.CollectionDraft(
            id: f2Key, finalName: fuOut.lastPathComponent, existingFolders: [], suggestedFolders: [],
            chosenExisting: fuOut, segmentCount: 1, photoCount: 1)])
        let reclaimed = await fuSettle { !fuProc.isFinalizing && fuProc.staged.isEmpty }
        check("a clean batch reclaims while a page of an unplanned group is still mid-OCR",
              reclaimed && paidStarts() == 4
                  && fuPhoto("F3", 1).map { fuProc._recoveryTestHasPageTask(for: $0) } == true)
        fuSend("F3", 1)
        check("...and that page's re-upload still buys NO second call after the reclaim",
              paidStarts() == 4)
        fuGate4.open()

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        LiveCaptureProcessor._recoveryTestOCRGate = nil
    }

    /// Test 18 (W3.cap-r3-fu2) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest18(tmp: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // Same isolation as Tests 16/17, load-bearing for the same reason: `CaptureSession.init` adopts
        // the newest backup session that still holds unprocessed photos, so inherited photos would put
        // pages in this session it never ingested and `paidStarts()` counts starts for the whole run.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let ruOut = tmp.appendingPathComponent("fu2out", isDirectory: true)
        let ruStaging = tmp.appendingPathComponent("APStaging-fu2-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: ruStaging, withIntermediateDirectories: true)
        let ruSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        ruSession._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — a document only reaches the LLM in `.automatic`, so the re-finalize the
                // retry triggers runs for real, for $0, with no network.
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: ruOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: ruStaging)
        let ruProc = ruSession.liveProcessor
        let ruBytes = Data("synthetic page bytes".utf8)
        func ruSend(_ gid: String, _ seq: Int) {
            ruSession.ingest(jpeg: ruBytes, groupId: gid, seq: seq, type: .document,
                             quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        func ruSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func paidStarts() -> Int { LiveCaptureProcessor._recoveryTestOCRStarts.count }
        func ruPhoto(_ gid: String, _ seq: Int) -> CapturedPhoto? {
            ruSession.photos.first { $0.groupId == gid && $0.seq == seq }
        }
        // The handle kept OUTSIDE `pageTasks` (W3.cap-r3): dropping the entry is exactly what makes the
        // Task unreachable everywhere else, so this is the only vantage from which a genuine `cancel()`
        // can be told from a silent drop — both leave `pageTasks` without that key.
        func ruTask(_ p: CapturedPhoto) -> Task<OCRResult, Never>? {
            LiveCaptureProcessor._recoveryTestOCRTasks[LiveCaptureProcessor.PageKey(p)]
        }
        func textPages(_ gid: String) -> Int {
            (ruProc.retainedText(for: gid) ?? "").components(separatedBy: "stub page text").count - 1
        }

        // 1. Two pages of the group to be retried, plus a page of a DIFFERENT group, all parked mid-OCR.
        //    A finished Task cannot be shown to have been cancelled, so without the gate every assertion
        //    below would be vacuous.
        let ruGate = TestGate()
        LiveCaptureProcessor._recoveryTestOCRGate = { await ruGate.wait() }
        ruSend("U1", 1)
        ruSend("U1", 2)
        ruSend("U2", 1)
        LiveCaptureProcessor._recoveryTestOCRGate = nil   // hold only these three; the re-ingest runs free
        let u1 = ruPhoto("U1", 1), u2 = ruPhoto("U1", 2), other = ruPhoto("U2", 1)
        // Captured BEFORE the retry: the re-ingest inside it overwrites these entries with the new Tasks.
        let oldT1 = u1.flatMap(ruTask), oldT2 = u2.flatMap(ruTask)
        check("the group's two pages bought calls that are genuinely in flight and uncancelled",
              u1 != nil && u2 != nil && other != nil && paidStarts() == 3
                  && oldT1?.isCancelled == false && oldT2?.isCancelled == false
                  && u1.map { ruProc._recoveryTestHasPageTask(for: $0) } == true)

        // 2. The reachability claim this item rests on, pinned rather than asserted in prose. It has TWO
        //    independent legs and both are checked here: a segment in this state renders as `.processing`,
        //    for which the shared per-item menu offers NOTHING; and it is absent from `failedGroupIds`,
        //    which is the entire input of the bulk "Retry N failed" button. If a future edit reaches this
        //    loop through either one, the matching check fails — and whoever sees it should re-read the
        //    comment on `retryFailed`'s cancel loop, which is what keeps that edit safe. Scope of the
        //    second leg, since it asserts an absence: it pins that a group in THIS state is not in the
        //    bulk retry's input. It cannot see the lifecycle path of `W3.cap-r3-fu5` — a group that fails,
        //    is later filed by the rotation review, and used to stay in `failedGroupIds` after losing its
        //    late-page cover — because nothing in this session ever fails. Test 19 drives that one.
        //    `finalizing: false` below is on purpose: this leg is about the STATE offering nothing, so it
        //    must not be able to pass because of `W3.cap-r3-fu7`'s separate mid-regeneration gate, which
        //    Test 21 drives.
        let midOCR = ruProc.statuses.first { $0.id == "U1" }
        let midOCRActions = midOCR.map {
            SegmentItem.actions(for: SegmentItem.state(for: $0), finalizing: false)
        }
        check("no retry is offered for a segment mid-OCR — the reason the drop-without-cancel was latent",
              midOCR?.phase == .ocr && midOCRActions?.isEmpty == true)
        check("...and the bulk retry cannot reach it either: a mid-OCR group is in no failed set",
              !ruProc.failedGroupIds.contains("U1") && !ruProc.failedGroupIds.contains("U2"))

        // 3. THE FIX. The retry replaces every one of this group's entries, so the calls it drops can
        //    never be read again — they have to be cancelled on the way out.
        ruProc.retryFailed(groupIds: ["U1"])
        check("a retry CANCELS the in-flight calls it is dropping",
              oldT1?.isCancelled == true && oldT2?.isCancelled == true)

        // 4. Scoped to the group being retried. A fix that cancelled `pageTasks.values` wholesale would
        //    silently kill the calls of every other segment the operator is still capturing.
        check("...and leaves another group's in-flight call running and reachable",
              other.map { ruTask($0)?.isCancelled == false
                          && ruProc._recoveryTestHasPageTask(for: $0) } == true)

        // 5. The retry still does its own job — cancelling must not eat the replacements. Its whole point
        //    is to buy this group's OCR again, so each page gets a fresh, uncancelled call under the same
        //    key, and it is not the one just cancelled.
        let newT1 = u1.flatMap(ruTask), newT2 = u2.flatMap(ruTask)
        check("...while re-ingesting the group: a fresh call per page, neither of them the cancelled one",
              paidStarts() == 5 && newT1 != nil && newT2 != nil
                  && newT1?.isCancelled == false && newT2?.isCancelled == false
                  && newT1 != oldT1 && newT2 != oldT2)

        // 6. The retry's own product, measured on the OUTPUT: the re-finalize it triggers reads the NEW
        //    calls, so the segment stages with both pages of text — the mechanism must not cost the retry
        //    the thing it exists to do. Stated honestly, this check is a guard against over-reach rather
        //    than a second catcher of the fix: the $0 stub is cancellation-blind BY DESIGN (it has to park
        //    on the gate for the checks above, and a cancelled stub still returns its text), so an
        //    after-the-re-ingest cancel does not show up here — check 5 is what kills that one. The drop
        //    is what this check is aimed at (cancel-without-`= nil` leaves the old entry in place, the
        //    started-once guard refuses the re-ingest, and the group can never stage again) — but M4 is
        //    also the mutant that stops the run before this line reports, so in practice check 5 catches
        //    that one too. No measured mutant reddens this check alone.
        let restaged = await ruSettle { ruProc.staged.contains { $0.groupId == "U1" } }
        check("...and the retried segment stages with both pages of the OCR it just paid for",
              restaged && textPages("U1") == 2)

        ruGate.open()   // release the three parked pages; nothing after this reads them
        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        LiveCaptureProcessor._recoveryTestOCRGate = nil
    }

    /// Test 19 (W3.cap-r3-fu5) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest19(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        // Same isolation as Tests 16–18, and load-bearing for the same reason: `CaptureSession.init`
        // adopts the newest backup session that still holds unprocessed photos, so inherited photos would
        // put pages in this session it never ingested.
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let fvOut = tmp.appendingPathComponent("fu5out", isDirectory: true)
        let fvStaging = tmp.appendingPathComponent("APStaging-fu5-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: fvStaging, withIntermediateDirectories: true)
        let fvSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        fvSession._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` — a document only reaches the LLM in `.automatic`, so both finalizes below run
                // for real, for $0, with no network.
                taggingMode: .human, rotationMode: .off, mergeDocuments: false,
                outputDirectory: fvOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: fvStaging)
        let fvProc = fvSession.liveProcessor
        func fvSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func fvChmod(_ mode: Int) {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: fvStaging.path)
        }

        // 1. PREMISE. Fail the segment the way the item describes — a TRANSIENT write error, not a lost
        //    source. `writeSegmentFiles` records only a PDF it can prove is on disk, so a staging dir it
        //    cannot write into yields none at all → `.noOutput` → `markFailed`. The source photo lives in
        //    the backup root and is untouched, which is exactly why step 3's regeneration can succeed
        //    where this write did not. The subset is asserted HERE too: at the moment of failure the
        //    group is in both sets, which is the state the rest of the section watches.
        //    TWO groups fail, and only V1 is rotated below — so V2 is a segment that is STILL genuinely
        //    failed and unfiled when the batch files V1. It is what makes the scoping load-bearing: a
        //    `releaseFinalizedGroup` that cleared the failed set wholesale would take the operator's one
        //    real retry with it, and nothing else in this driver would notice.
        fvChmod(0o555)
        for gid in ["V1", "V2"] {
            fvSession.ingest(jpeg: Data("synthetic page bytes".utf8), groupId: gid, seq: 1,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
            fvProc.segmentResolved(groupId: gid)
        }
        let fvFailed = await fvSettle {
            fvProc.failedGroupIds.contains("V1") && fvProc.failedGroupIds.contains("V2")
        }
        fvChmod(0o755)   // the error was transient; from here the dir is writable again
        check("a transient staging write error fails both segments with NO output, inside both sets",
              fvFailed && fvProc.statuses.first { $0.id == "V1" }?.phase == .failed
                  && fvProc.isFinalized("V1") && fvProc.isFinalized("V2")
                  && fvProc.staged.first { $0.groupId == "V1" }?.pdfURLs.isEmpty == true
                  && fvProc.staged.first { $0.groupId == "V2" }?.pdfURLs.isEmpty == true)

        // 2. PREMISE. A failed segment's pages still reach the end-of-session rotation review, because
        //    `finishSession` enumerates `retained.values` and nothing filters by label. Driven through the
        //    real Finish rather than by poking `rotationReviewPages`: the "Review rotation" default is the
        //    only input, and it is set and restored around the single SYNCHRONOUS call that reads it
        //    (`finishSession` is not `async`, and there is no `await` in this block), so this never
        //    leaves the operator's own toggle flipped. Two residuals an adversarial pass named, both
        //    accepted: a crash or SIGTERM inside that window would leave it ON — this is the driver's
        //    only isolation not done by env var — and `object(forKey:)` reads through the domain search
        //    list, so a value inherited from a global domain would be written INTO the app domain by the
        //    restore. Negligible for an app-private key, but it is not nothing.
        let priorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
        fvProc.finishSession()
        if let priorReview {
            UserDefaults.standard.set(priorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        check("a FAILED segment's pages still enter the end-of-session rotation review",
              fvProc.showRotationReview
                  && fvProc.rotationReviewPages.contains { $0.groupId == "V1" })

        // 3. PREMISE. The operator corrects a rotation, so the review regenerates the segment — and this
        //    time the write lands. The staged record is replaced wholesale, so a group that is still
        //    counted failed is now one `executePlans` will file. Without this the finalize below would
        //    file nothing and check 5 would pass for the wrong reason.
        for i in fvProc.rotationReviewPages.indices where fvProc.rotationReviewPages[i].groupId == "V1" {
            fvProc.rotationReviewPages[i].rotationDegrees = 90
        }
        fvProc.applyRotationReviewAndFinalize()
        let fvRegen = await fvSettle {
            !fvProc.isFinalizing && fvProc.staged.first { $0.groupId == "V1" }?.pdfURLs.isEmpty == false
        }
        let fvRecord = fvProc.staged.first { $0.groupId == "V1" }
        check("the rotation review regenerates that record into a FILABLE one — a PDF proven on disk",
              fvRegen && fvRecord?.pagesComplete != false
                  && fvRecord?.pdfURLs.first.map { fm.fileExists(atPath: $0.path) } == true)

        // 4. THE FIX (W3.cap-r3-fu6) — and it RECONCILES the label while doing it. This check is the one
        //    fu5 predicted would flip: it used to PIN the stale `.failed`, because fu5 needed a filable
        //    group that was still counted failed and this was how that state arose. fu6 closed it at
        //    source — `applyRotationReviewAndFinalize` now re-derives the label from the record it just
        //    wrote (`labelStagedRecord`), so the "1 segment(s) failed to process and are NOT filed —
        //    Retry them before finalizing" warning no longer names a segment that is fine, and the
        //    operator can no longer be talked into a `retryFailed` that deletes the freshly regenerated
        //    output and re-buys its OCR.
        //    `.succeededPlaceholderImage`, not `.staged`, and that is not incidental: the synthetic bytes
        //    are not a decodable image, so `generate` embeds the deliberate placeholder page (check 7
        //    below turns on the same fact). Asserted as the SPECIFIC label the taxonomy owes this record
        //    rather than "not failed", so a fix that reconciled the sets by blanket-clearing them would
        //    still be caught — as would one that forgot the reason line, which is what the row shows.
        //    The `== ["V2"]` equality is the over-reach half: V2 is genuinely failed and was NOT
        //    regenerated, so a relabel that cleared the whole set would take the operator's one real
        //    retry with it.
        check("...and RECONCILES the label with it — a regenerated record is no longer counted failed",
              !fvProc.failedGroupIds.contains("V1")
                  && fvProc.failedGroupIds == ["V2"]
                  && fvProc.statuses.first { $0.id == "V1" }?.phase == .succeededPlaceholderImage
                  && fvProc.statuses.first { $0.id == "V1" }?.failureKind == nil)

        // 5. THE FIX (fu5). Finish files it, and a filed group leaves BOTH sets together. Since fu6 the
        //    group has ALREADY left the failed set at check 4, so what follows now confirms the pairing
        //    holds rather than catching it failing — see the M1 re-measurement in the header. Kept
        //    verbatim on purpose: it is still the only place in this driver that drives a real `finalize`
        //    over a segment that reached it through the rotation review.
        fvProc.finalize([LiveCaptureProcessor.CollectionDraft(
            id: fvRecord?.collectionKey ?? "__unfiled__", finalName: fvOut.lastPathComponent,
            existingFolders: [], suggestedFolders: [], chosenExisting: fvOut,
            segmentCount: 1, photoCount: 1)])
        let fvFiled = await fvSettle {
            !fvProc.isFinalizing && !fvProc.staged.contains { $0.groupId == "V1" }
        }
        // Deliberately worded unlike Test 17's near-identical premise: the two shared a name while the
        // mutants below were being read, and a FAIL line is all a reader gets.
        check("the REGENERATED document really filed, so what follows is its post-filing state",
              fvFiled && ((try? fm.contentsOfDirectory(at: fvOut, includingPropertiesForKeys: nil)) ?? [])
                  .contains { $0.pathExtension == "pdf" })
        check("a FILED group leaves the failed set with the finalized one — the subset survives the file",
              !fvProc.failedGroupIds.contains("V1") && !fvProc.isFinalized("V1"))
        // WHICH shape this section builds, pinned because the cost of the leftover entry depends on it
        // and an adversarial pass corrected the fix's first claim about that. The synthetic bytes are
        // not a decodable image, so `generate` embeds the deliberate PLACEHOLDER page and finalize
        // WITHHOLDS V1's source — which keeps the group alive in `session.groups`. That is the minority
        // case where a leftover failed entry is EXPENSIVE: `retryFailed` finds the group, re-ingests it
        // and buys its OCR again. In the ordinary filed-with-a-real-scan case the source is retired,
        // `groups` (derived from `photos`) no longer has it, and the phantom button self-clears at
        // `retryFailed`'s `else` guard — confusing, but free. Both are wrong; only this one costs money.
        check("...and this is the placeholder shape, where that entry was expensive and not cosmetic",
              fvSession.groups.contains { $0.id == "V1" }
                  && fvSession.photos.contains { $0.groupId == "V1" })
        // The operator-visible shape of the same thing, and the pairing that made it confusing rather
        // than merely wrong: `failedGroupIds.count` IS the "Retry N failed" button, and the row that
        // would have explained the count is dropped by the same finalize. Asserted as an EQUALITY
        // against the one segment that genuinely failed, so it catches both directions — the filed
        // group left in (the bug) and the unfiled one swept out with it (over-reach).
        check("...so the button counts exactly the segment that is still failed, and it has a row",
              fvProc.failedGroupIds == ["V2"]
                  && !fvProc.statuses.contains { $0.id == "V1" }
                  && fvProc.statuses.contains { $0.id == "V2" && $0.phase == .failed })

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }

    /// Test 20 (W3.cap-r3-fu6) of `run()`, moved out whole (W49.proc-build-memory): inside `run()`, type-checking and
    /// lowering that one function took a single swift-frontend to 9.4 GB. Runs only with a scratch backup root.
    static func runTest20(tmp: URL, staging: URL, stubModel: LLMModel, check: (String, Bool) -> Void) async {
        let fm = FileManager.default
        if let testRoot = ProcessInfo.processInfo.environment["ARCHIVEPROC_TEST_BACKUP_ROOT"],
           !testRoot.isEmpty {
            let entries = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: testRoot),
                                                       includingPropertiesForKeys: nil)) ?? []
            for e in entries where CaptureSession.isSessionIdName(e.lastPathComponent) {
                try? fm.removeItem(at: e)
            }
        }
        let bwOut = tmp.appendingPathComponent("fu6out", isDirectory: true)
        let bwStaging = tmp.appendingPathComponent("APStaging-fu6-\(String(UUID().uuidString.prefix(8)))",
                                                   isDirectory: true)
        try? fm.createDirectory(at: bwStaging, withIntermediateDirectories: true)
        let bwSession = CaptureSession()
        LiveCaptureProcessor._recoveryTestOCRStub =
            OCRResult(text: "stub page text", classification: nil, errorMessage: nil, errorCode: nil)
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
        bwSession._recoveryTestBeginLive(
            config: SessionProcessingConfig(
                provider: .gemini, model: stubModel, thinkingLevel: .low, apiKey: "",
                // `.human` again — no document reaches the LLM, so this runs for real, for $0, no network.
                taggingMode: .human, rotationMode: .off,
                // Load-bearing, not incidental: see the merge note above.
                mergeDocuments: true,
                outputDirectory: bwOut,
                customOCRPrompt: "", imageScale: 1.0, enableSegmentJSON: false, tagVocabulary: [],
                gateway: nil, outputImageFile: false, pdfImageMB: 2.0, exportedImageMB: 3.0,
                textColumns: 1),
            stagingDir: bwStaging)
        let bwProc = bwSession.liveProcessor
        func bwSettle(_ cond: () -> Bool) async -> Bool {
            for _ in 0..<400 { if cond() { return true }; try? await Task.sleep(nanoseconds: 25_000_000) }
            return cond()
        }
        func bwChmod(_ mode: Int) {
            try? fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: bwStaging.path)
        }
        // A REAL, decodable JPEG this time (Test 19 uses undecodable bytes on purpose). Two reasons: the
        // segment must reach the plain `.staged` label the item names, which a placeholder page would
        // pre-empt with `.succeededPlaceholderImage`; and the merge below only happens if both pages
        // actually produce a PDF.
        let bwBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                        bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                        isPlanar: false, colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0)
        let bwJPEG = bwBitmap?.representation(using: .jpeg, properties: [:]) ?? Data()

        // 1. PREMISE. A two-page document stages CLEANLY — the success label this section watches decay.
        //    The staging itself is awaited, not a deadline (W49.recov-fu6-flake): these are the run's first
        //    decodable pages through live staging, so this write is its first Apple Vision reading (the text
        //    layer's), which can wait about 30 s for the Neural Engine to compile its model again after a
        //    rebuild (W40.fix-processor-date-route-live-flake). A hang still fails: the script times out.
        bwProc._testFinalizeTasks = []
        for seq in [1, 2] {
            bwSession.ingest(jpeg: bwJPEG, groupId: "B1", seq: seq,
                             type: .document, quality: nil, year: nil, month: nil, deviceName: "TestPhone")
        }
        bwProc.segmentResolved(groupId: "B1")
        await bwProc._testAwaitFinalizes()
        bwProc._testFinalizeTasks = nil
        let bwStagedOK = bwProc.statuses.first { $0.id == "B1" }?.phase == .staged
        let bwFirst = bwProc.staged.first { $0.groupId == "B1" }
        check("a two-page document stages cleanly as ONE merged PDF, in no failed set",
              bwStagedOK && bwProc.failedGroupIds.isEmpty
                  && bwFirst?.pagesComplete != false && bwFirst?.pdfURLs.count == 1
                  && bwFirst?.pdfURLs.first.map { fm.fileExists(atPath: $0.path) } == true)

        // 2. PREMISE, and the one that stops this section being vacuous: the merge deleted the per-page
        //    PDFs, so the paths the regeneration will write to are ABSENT. Without this a failed write
        //    would be masked by the previous run's file and check 4 would pass for no reason.
        let bwSources = bwSession.photos.filter { $0.groupId == "B1" }.map(\.url)
        let bwPerPage = bwSources.map {
            bwStaging.appendingPathComponent($0.deletingPathExtension().lastPathComponent + ".pdf")
        }
        check("...and the merge left its per-page paths EMPTY, so the regeneration writes fresh",
              bwSources.count == 2 && bwPerPage.allSatisfy { !fm.fileExists(atPath: $0.path) })

        // 3. PREMISE. The staged segment's pages reach the rotation review (as in Test 19, driven through
        //    the real Finish, with the operator's own toggle restored around the one synchronous call).
        bwChmod(0o555)   // from here the write cannot land — the transient failure this half needs
        let bwPriorReview = UserDefaults.standard.object(forKey: DefaultsKeys.reviewRotation)
        UserDefaults.standard.set(true, forKey: DefaultsKeys.reviewRotation)
        bwProc.finishSession()
        if let bwPriorReview {
            UserDefaults.standard.set(bwPriorReview, forKey: DefaultsKeys.reviewRotation)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKeys.reviewRotation)
        }
        check("a STAGED segment's pages enter the end-of-session rotation review",
              bwProc.showRotationReview
                  && bwProc.rotationReviewPages.filter { $0.groupId == "B1" }.count == 2)

        // 4. PREMISE. The operator straightens a page; the regeneration runs and produces nothing.
        for i in bwProc.rotationReviewPages.indices
        where bwProc.rotationReviewPages[i].groupId == "B1" && bwProc.rotationReviewPages[i].pageIndex == 0 {
            bwProc.rotationReviewPages[i].rotationDegrees = 90
        }
        bwProc.applyRotationReviewAndFinalize()
        let bwRegen = await bwSettle { !bwProc.isFinalizing && bwProc.showFinalizeSheet }
        bwChmod(0o755)   // restore before the finalize + the temp-dir cleanup at the end of the run
        let bwRecord = bwProc.staged.first { $0.groupId == "B1" }
        check("the regeneration produced NOTHING — the record that replaced it holds no PDF at all",
              bwRegen && bwRecord?.pdfURLs.isEmpty == true && bwRecord?.pagesComplete == false)

        // 5. THE FIX. The label went down with the record. Before this, the segment kept "Staged" over an
        //    empty record and the operator was told nothing at all; now it is `.failed` with a reason and
        //    in the retry set, which is the only way the situation is recoverable — the sources are still
        //    in the backup folder and a retry regenerates them. Asserted as an equality so a fix that
        //    marked everything failed would not pass either.
        check("...and the label went down with it: FAILED, with a reason, and offered for retry",
              bwProc.failedGroupIds == ["B1"]
                  && bwProc.statuses.first { $0.id == "B1" }?.phase == .failed
                  && bwProc.statuses.first { $0.id == "B1" }?.failureKind == .noOutput)

        // 6. …and the outcome that was silent is now stated. `executePlans` declines to file the empty
        //    record either way — that gate is unchanged and is not what this item touched — but the
        //    segment now survives finalize with a row and a count against it, instead of vanishing from
        //    the collection with the sheet reporting nothing wrong.
        bwProc.finalize([LiveCaptureProcessor.CollectionDraft(
            id: bwRecord?.collectionKey ?? "__unfiled__", finalName: bwOut.lastPathComponent,
            existingFolders: [], suggestedFolders: [], chosenExisting: bwOut,
            segmentCount: 1, photoCount: 2)])
        let bwFinalized = await bwSettle { !bwProc.isFinalizing && !bwProc.showFinalizeSheet }
        check("finalize files nothing and SAYS so — the segment keeps its row, its count and its sources",
              bwFinalized
                  && !((try? fm.contentsOfDirectory(at: bwOut, includingPropertiesForKeys: nil)) ?? [])
                      .contains { $0.pathExtension == "pdf" }
                  && bwProc.staged.contains { $0.groupId == "B1" }
                  && bwProc.failedGroupIds == ["B1"]
                  && bwProc.statuses.contains { $0.id == "B1" && $0.phase == .failed }
                  && bwSources.allSatisfy { fm.fileExists(atPath: $0.path) })

        LiveCaptureProcessor._recoveryTestOCRStub = nil
        LiveCaptureProcessor._recoveryTestOCRStarts = []
        LiveCaptureProcessor._recoveryTestOCRTasks = [:]
    }
}

#endif
