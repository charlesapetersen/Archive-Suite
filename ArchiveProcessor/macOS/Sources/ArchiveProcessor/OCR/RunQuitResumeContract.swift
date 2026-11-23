#if DEBUG // W40.a5: a test driver/contract, compiled out of Release
import AppKit
import Foundation
import PDFKit

/// Key-free, no-network contract for W49.proc-resume-standard-runs. An interrupted standard Files run, resumed through
/// the REAL `resumeRun` over the injected HTTP transport, is asked to quit while pages are being read: it must start no
/// new page, save the pages in flight to the run's manifest, stop with the manifest kept and then quit; a second
/// resume reads only the pages left, and no page is read twice. Also the Interrupted Run box's note for pages missing
/// since the run began, the guard that sends nothing for them, the sleep hold, and a Stop that takes the quit back.
/// W49.proc-stop-saves-inflight: Stop waits the same way (and Stop Now does not), and the mixed-PDF route waits too.
/// W49.proc-quit-waits-batch-submit: a quit or Stop during a paid batch's create request waits for its reply.
/// The journal is redirected into a temporary directory the way `InstitutionalComputeImportTestDriver` does it;
/// nothing outside it is read or written.
///
/// Run via `scripts/test-run-quit-resume.sh`.
@MainActor
enum RunQuitResumeContract {
    nonisolated static let envKey = "RUN_QUIT_RESUME_TEST"
    private static var didRun = false

    static func runIfRequested() {
        guard !didRun, ProcessInfo.processInfo.environment[envKey] == "1" else { return }
        didRun = true
        Task { await run() }
    }

    /// Holds every request until released, and counts them.
    private actor Gate {
        var open = false
        var arrived = 0
        func arrive() { arrived += 1 }
        func isOpen() -> Bool { open }
        func release() { open = true }
        func close() { open = false }
        func count() -> Int { arrived }
    }

    private final class QuitCount { var value = 0 }

    static func run() async {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("APRunQuitResume-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        var results: [String] = []
        func check(_ name: String, _ condition: Bool, _ detail: String = "") {
            results.append("\(condition ? "PASS" : "FAIL"): \(name)\(condition || detail.isEmpty ? "" : " — \(detail)")")
        }

        let stateRoot = root.appendingPathComponent("state", isDirectory: true)
        let saved = ["BATCHRESUME_TEST", "ARCHIVEPROC_TEST_STATE_ROOT"].map { ($0, ProcessInfo.processInfo.environment[$0]) }
        setenv("BATCHRESUME_TEST", "1", 1)
        setenv("ARCHIVEPROC_TEST_STATE_ROOT", stateRoot.path, 1)
        defer { for (key, value) in saved { if let value { setenv(key, value, 1) } else { unsetenv(key) } } }
        let manifest = OCRProcessor.pendingRunURL
        guard manifest.deletingLastPathComponent().standardizedFileURL == stateRoot.standardizedFileURL else {
            finish(["FAIL: the resume journal is redirected into scratch — \(manifest.path)"])
            return
        }
        try? fm.createDirectory(at: stateRoot, withIntermediateDirectories: true)

        let input = root.appendingPathComponent("input", isDirectory: true)
        let output = root.appendingPathComponent("output", isDirectory: true)
        try? fm.createDirectory(at: output, withIntermediateDirectories: true)
        let pages = (1...8).map { input.appendingPathComponent(String(format: "p%02d.jpg", $0)) }
        guard pages.dropLast().allSatisfy({ makeJPEG($0, shade: 0.1 * Double(pages.firstIndex(of: $0)! + 1)) }) else {
            finish(["FAIL: fixture JPEGs could not be created"])
            return
        }

        let gate = Gate()
        NetworkSession.testTransport = { request in
            await gate.arrive()
            while !(await gate.isOpen()) { try await Task.sleep(nanoseconds: 20_000_000) }
            let body = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"[document_start]\nPAGE-TEXT"}]}}]}"#
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!, statusCode: 200,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
        OCRRefusalFallback.routesOverride = { [] }
        let quits = QuitCount()
        OCRProcessor.quitApp = { quits.value += 1 }
        defer {
            NetworkSession.testTransport = nil
            OCRRefusalFallback.routesOverride = nil
            OCRProcessor.quitApp = nil
            OCRProcessor.quitApproved = false
        }
        guard NetworkSession.testTransportIsActive else {
            finish(["FAIL: the injected transport is active — stopping before any request"])
            return
        }

        // The run as it was interrupted: six pages, none read, no tagging, rotation off, two workers.
        let model = LLMModel.geminiModels[0]
        let suite = "APRunQuitResume-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defer { defaults.removePersistentDomain(forName: suite) }
        var config = SessionProcessingConfig.fromProcessFilesRunStart(defaults)
        config.ocrWorkerCount = 2
        let builder = OCRProcessor()
        builder.taggingMode = .none
        builder.rotationMode = .off
        let runtime = builder.makePendingRunRuntimeConfig(imageScale: 1, gatewayConfig: nil, runConfig: config)
        var run = OCRProcessor.PendingRun(
            provider: .gemini, model: model, thinkingLevel: nil, fileURLs: pages, outputDirectory: output,
            enableTagging: false, enableSegmentJSON: false, enableCollectionSegmentation: false,
            confirmCollectionIDs: false, reviewDocumentSegmentation: false, preOCRedInput: false,
            previousTextCharCount: 0, sendPreviousImage: false, customPrompt: nil, startedAt: Date(),
            gatewayConfig: nil, completedResults: [:], runFingerprint: nil, exportOriginals: false,
            localAgent: nil, runtimeConfig: runtime)
        run.runFingerprint = OCRProcessor.pendingRunFingerprintV2(run)
        guard OCRProcessor.pendingRunIsSelfConsistent(run), OCRProcessor._testWritePendingRun(run, to: manifest) else {
            finish(["FAIL: the interrupted run's manifest is written and valid"])
            return
        }

        // 1. A page gone since the run began: said before Resume, and sent nowhere.
        let note = OCRProcessor.pendingRunMissingNote(run)
        check("the Interrupted Run box names a page no longer where the run found it",
              note.contains("1 file not yet read is no longer where the run found it"), note)
        let box = OCRProcessor()
        box.checkForPendingBatch()
        check("the note is part of the box's text", box.pendingRunInfo?.hasSuffix(note) == true,
              box.pendingRunInfo ?? "nil")
        let missing = await OCRProcessor.performOCRCall(
            imageURL: pages[pages.count - 1], provider: .gemini, model: model, thinkingLevel: nil, apiKey: "test-key",
            previousText: nil, previousImageURL: nil, rotationMode: .off, standardImageMB: 3, cascade: .off)
        let requestsForMissing = await gate.count()
        check("a missing page fails before any request", missing.text == nil && missing.errorCode == "source_missing"
              && requestsForMissing == 0, "\(missing.errorCode ?? "nil"), \(requestsForMissing) requests")
        guard makeJPEG(pages[pages.count - 1], shade: 0.9) else { finish(results + ["FAIL: the sixth page is put back"]); return }
        check("with the page back the note is gone", OCRProcessor.pendingRunMissingNote(run).isEmpty)

        // 2. Quit while pages are being read.
        let first = OCRProcessor()
        let firstRun = Task { await first.resumeRun(apiKey: "test-key") }
        first.processingTask = firstRun
        let started = await waitFor { await gate.count() >= 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)   // let the second worker's request arrive too
        let inFlight = await gate.count()
        check("the resumed run reads pages in its main pass", started && first.ocrPhaseActive && first.isProcessing,
              "\(inFlight) requests")
        check("a run reading pages holds off idle sleep", first.runActivity != nil && first.runActivityHoldsSleep)
        check("the running processor is the one a quit asks about",
              OCRProcessor.processorsStillRunning.contains { $0 === first })
        first.beginQuitWhenPagesSaved()
        check("the quit waits for the pages in flight", first.quitWhenPagesSaved
              && first.statusMessage == OCRProcessor.quitWaitMessage, first.statusMessage)
        await gate.release()
        await firstRun.value
        let quit = await waitFor { quits.value == 1 }
        let afterQuit = OCRProcessor._testReadPendingRun(from: manifest)
        let requestsAfterQuit = await gate.count()
        check("no page is started once the quit is asked", requestsAfterQuit == inFlight,
              "\(inFlight) before, \(requestsAfterQuit) after")
        check("every page in flight is saved to the manifest", afterQuit?.completedResults.count == inFlight
              && afterQuit?.completedResults.values.allSatisfy { $0.text != nil } == true,
              "\(afterQuit?.completedResults.count ?? -1) saved of \(inFlight)")
        check("the run stops with its manifest kept, then the app quits once",
              quit && quits.value == 1 && OCRProcessor.quitApproved && !first.isProcessing && afterQuit != nil,
              "quits \(quits.value), processing \(first.isProcessing)")
        check("a stopped run lets the Mac sleep again", first.runActivity == nil)
        let leftAfterQuit = afterQuit.map {
            OCRProcessor.remainingIndices(totalFiles: $0.fileURLs.count, completedResults: $0.completedResults) } ?? []
        check("Resume Run would start from the first page not read", leftAfterQuit == Array(inFlight..<pages.count),
              "\(leftAfterQuit)")
        OCRProcessor.quitApproved = false

        // 3. The next resume reads only the pages left, and none twice.
        await gate.close()
        let second = OCRProcessor()
        let secondRun = Task { await second.resumeRun(apiKey: "test-key") }
        second.processingTask = secondRun
        _ = await waitFor { await gate.count() > inFlight }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let readAgain = await gate.count() - inFlight
        second.beginQuitWhenPagesSaved()
        await gate.release()
        await secondRun.value
        _ = await waitFor { quits.value == 2 }
        let afterSecond = OCRProcessor._testReadPendingRun(from: manifest)
        let firstKeys = Set(afterQuit?.completedResults.keys.map { $0 } ?? [])
        let secondKeys = Set(afterSecond?.completedResults.keys.map { $0 } ?? [])
        check("the second resume reads only pages the first did not", readAgain > 0
              && secondKeys.count == inFlight + readAgain && secondKeys.isSuperset(of: firstKeys),
              "\(readAgain) read, \(secondKeys.sorted()) saved")
        let published = ((try? fm.contentsOfDirectory(atPath: output.path)) ?? []).filter { $0.hasSuffix(".pdf") }
        let working = OCRProcessor.savedCatalogueRun()?.workingRoot
        let staged = working.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) } ?? []
        let pdfs = staged.filter { $0.hasSuffix(".pdf") }
        let recordedPaths = Set(afterSecond?.completedOutputPaths?.values.map {
            URL(fileURLWithPath: $0).lastPathComponent
        } ?? [])
        check("each saved page has one private PDF and quit exposes no incomplete output",
              pdfs.count == secondKeys.count && Set(pdfs) == recordedPaths && published.isEmpty,
              "working \(pdfs.sorted()), published \(published.sorted())")
        OCRProcessor.quitApproved = false

        // 4. Stop pressed while the quit waits takes the quit back.
        await gate.close()
        let third = OCRProcessor()
        let thirdRun = Task { await third.resumeRun(apiKey: "test-key") }
        third.processingTask = thirdRun
        _ = await waitFor { await gate.count() > inFlight + readAgain }
        third.beginQuitWhenPagesSaved()
        third.cancel()
        await gate.release()
        await thirdRun.value
        try? await Task.sleep(nanoseconds: 300_000_000)
        check("Stop takes a waiting quit back", !third.quitWhenPagesSaved && quits.value == 2
              && !OCRProcessor.quitApproved && fm.fileExists(atPath: manifest.path), "quits \(quits.value)")

        // 5. Stop waits for the pages in flight too, and the app stays open (W49.proc-stop-saves-inflight).
        await gate.close()
        let savedBeforeStop = OCRProcessor._testReadPendingRun(from: manifest)?.completedResults.count ?? -1
        let requestsBeforeStop = await gate.count()
        let fourth = OCRProcessor()
        let fourthRun = Task { await fourth.resumeRun(apiKey: "test-key") }
        fourth.processingTask = fourthRun
        _ = await waitFor { await gate.count() > requestsBeforeStop }
        try? await Task.sleep(nanoseconds: 300_000_000)
        let stopInFlight = await gate.count() - requestsBeforeStop
        fourth.requestStop()
        check("Stop in the main pass waits for the pages in flight", fourth.stopWhenPagesSaved && fourth.isProcessing
              && fourth.statusMessage == OCRProcessor.stopWaitMessage, fourth.statusMessage)
        await gate.release()
        await fourthRun.value
        _ = await waitFor { !fourth.isProcessing }
        let afterStop = OCRProcessor._testReadPendingRun(from: manifest)
        let requestsAfterStop = await gate.count()
        check("no page is started once Stop is asked", requestsAfterStop == requestsBeforeStop + stopInFlight,
              "\(stopInFlight) in flight, \(requestsAfterStop - requestsBeforeStop) sent")
        check("every page in flight at Stop is saved to the manifest",
              stopInFlight > 0 && afterStop?.completedResults.count == savedBeforeStop + stopInFlight,
              "\(savedBeforeStop) before, \(afterStop?.completedResults.count ?? -1) after, \(stopInFlight) in flight")
        check("the waited Stop keeps the manifest and does not quit", !fourth.isProcessing && !fourth.drainingPages
              && quits.value == 2 && !OCRProcessor.quitApproved && afterStop != nil
              && fourth.statusMessage.hasSuffix(OCRProcessor.stoppedAfterDrainNote),
              "quits \(quits.value), \(fourth.statusMessage)")

        // 6. Stop Now, the second press, stops at once for a page that hangs.
        await gate.close()
        let requestsBeforeStopNow = await gate.count()
        let fifth = OCRProcessor()
        let fifthRun = Task { await fifth.resumeRun(apiKey: "test-key") }
        fifth.processingTask = fifthRun
        _ = await waitFor { await gate.count() > requestsBeforeStopNow }
        fifth.requestStop()
        let waiting = fifth.drainingPages
        fifth.requestStop()
        check("Stop Now stops at once while the page is still out", waiting && !fifth.drainingPages
              && !fifth.isProcessing && fm.fileExists(atPath: manifest.path) && quits.value == 2)
        await gate.release()
        await fifthRun.value

        // 7. Outside the main pass there is nothing in flight to wait for.
        let idle = OCRProcessor()
        idle.beginQuitWhenPagesSaved()
        check("a processor not reading pages does not wait", !idle.quitWhenPagesSaved)
        idle.isProcessing = true
        idle.requestStop()
        check("Stop outside the main pass stops at once", !idle.drainingPages && !idle.isProcessing)

        // 8. A run stopped at once that is still unwinding neither unmarks nor stops a newer run's pass.
        let reused = OCRProcessor()
        reused.isProcessing = true
        let stale = reused.beginDrainablePass()
        let current = reused.beginDrainablePass()
        reused.requestStop()
        reused.endDrainablePass(stale)
        check("an older pass ending leaves the newer one waiting", reused.ocrPhaseActive && reused.stopWhenPagesSaved
              && reused.isProcessing)
        reused.endDrainablePass(current)
        check("the newer pass ending finishes its own Stop", !reused.ocrPhaseActive && !reused.drainingPages
              && !reused.isProcessing)

        try? fm.removeItem(at: manifest)
        await mixedRouteWaits(root: root, gate: gate) { check($0, $1, $2) }
        await batchSubmissionWaits(root: root, quits: quits) { check($0, $1, $2) }
        finish(results)
    }

    /// The batch's requests in order, held until released; the create's reply is a job name or, failing, a 500.
    private actor BatchServer {
        var open = false
        var failCreate = false
        var urls: [String] = []
        func arrive(_ url: String) { urls.append(url) }
        func isOpen() -> Bool { open }
        func reset(failCreate: Bool) { open = false; self.failCreate = failCreate; urls = [] }
        func release() { open = true }
        func failing() -> Bool { failCreate }
        func sent() -> [String] { urls }
    }

    /// W49.proc-quit-waits-batch-submit: a quit or Stop asked while a paid batch's create request is out waits for the
    /// reply. A quit then leaves the job running, journaled as submitted, for Resume; Stop cancels it with the provider;
    /// a create that fails drops the wait, so the app stays open on the failure message.
    private static func batchSubmissionWaits(root: URL, quits: QuitCount,
                                             check: (String, Bool, String) -> Void) async {
        let server = BatchServer()
        NetworkSession.testTransport = { request in
            let url = request.url?.absoluteString ?? ""
            await server.arrive(url)
            while !(await server.isOpen()) { try await Task.sleep(nanoseconds: 20_000_000) }
            let failing = await server.failing()
            let failed = url.contains(":batchGenerateContent") && failing
            let job = url.contains(":batchGenerateContent") ? #"{"name":"batches/quit-test"}"# : "{}"
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://x.invalid")!,
                                           statusCode: failed ? 500 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data((failed ? #"{"error":{"message":"test failure"}}"# : job).utf8), response)
        }
        let image = root.appendingPathComponent("batch-page.jpg")
        let out = root.appendingPathComponent("batch-out", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard makeJPEG(image, shade: 0.4) else { check("the batch fixture is written", false, ""); return }
        let journal = OCRProcessor.pendingBatchURL
        let model = LLMModel.geminiModels[0]

        func submit(_ ask: (OCRProcessor) -> Void, failCreate: Bool = false) async -> (OCRProcessor, Bool, [String]) {
            OCRProcessor.deletePendingBatch()
            await server.reset(failCreate: failCreate)
            let processor = OCRProcessor()
            processor.taggingMode = .none
            processor.jobs = [OCRJob(sourceURL: image)]
            processor.isProcessing = true
            let run = Task {
                await processor.performBatchOCR(
                    fileURLs: [image], originalFiles: [image], provider: .gemini, model: model, thinkingLevel: nil,
                    apiKey: "test-key", outputDirectory: out, sendPreviousImage: false, enableTagging: false)
            }
            processor.processingTask = run
            let sent = await waitFor { await !server.sent().isEmpty }
            let waitable = sent && processor.ocrPhaseActive && processor.drainablePassKind == .batchSubmission
            ask(processor)
            await server.release()
            await run.value
            await processor.batchCancellationTask?.value
            try? await Task.sleep(nanoseconds: 300_000_000)
            return (processor, waitable, await server.sent())
        }

        // A quit: waits for the reply, records the job, quits, and asks the provider for nothing more.
        let quitsBefore = quits.value
        var askedMessage = ""
        let (quitter, quitWaitable, quitSent) = await submit {
            $0.beginQuitWhenPagesSaved()
            askedMessage = $0.statusMessage
        }
        _ = await waitFor { quits.value > quitsBefore }
        let kept = OCRProcessor._testReadPendingBatch(from: journal)
        check("a batch submission counts as a pass a quit can wait on", quitWaitable, quitSent.joined(separator: " "))
        check("the quit says it waits for the batch's reply", askedMessage == OCRProcessor.batchQuitWaitMessage,
              askedMessage)
        check("the quit lands once the job is journaled as submitted", quits.value == quitsBefore + 1
              && OCRProcessor.quitApproved && kept?.submissionComplete == true
              && kept?.submittedChunkIds == ["batches/quit-test"],
              "quits \(quits.value - quitsBefore), journal \(kept.map { "\($0.submittedChunkIds)" } ?? "none")")
        check("a quit neither cancels the job nor polls it", quitSent.count == 1 && !quitter.isProcessing
              && quitter.statusMessage == OCRProcessor.batchQuitRecordedMessage,
              "\(quitSent), \(quitter.statusMessage)")
        OCRProcessor.quitApproved = false

        // Stop: waits for the reply too, then cancels the job it now knows; the app stays open.
        let (stopper, _, stopSent) = await submit { $0.requestStop() }
        check("Stop during a batch submission waits, then cancels the recorded job",
              stopSent.count == 2 && stopSent[1].contains("batches/quit-test:cancel")
              && !stopper.isProcessing && !stopper.drainingPages && quits.value == quitsBefore + 1
              && !FileManager.default.fileExists(atPath: journal.path),
              "\(stopSent), journal \(FileManager.default.fileExists(atPath: journal.path) ? "kept" : "gone")")

        // Stop, then a quit: the Stop still cancels the job, and the app quits once that is done.
        let (both, _, bothSent) = await submit {
            $0.requestStop()
            $0.beginQuitWhenPagesSaved()
        }
        _ = await waitFor { quits.value > quitsBefore + 1 }
        check("a quit after Stop still cancels the job, then quits",
              bothSent.count == 2 && bothSent[1].contains("batches/quit-test:cancel") && quits.value == quitsBefore + 2
              && !both.isProcessing && !FileManager.default.fileExists(atPath: journal.path),
              "\(bothSent), quits \(quits.value - quitsBefore)")
        OCRProcessor.quitApproved = false

        // A create that fails: the run reports it and the quit is dropped, so the message stays on screen.
        let (failed, _, _) = await submit({ $0.beginQuitWhenPagesSaved() }, failCreate: true)
        check("a failed submission drops the waiting quit and keeps its journal", quits.value == quitsBefore + 2
              && !OCRProcessor.quitApproved && !failed.drainingPages && !failed.ocrPhaseActive && !failed.isProcessing
              && FileManager.default.fileExists(atPath: journal.path), failed.statusMessage)
        OCRProcessor.deletePendingBatch()
    }

    /// The mixed-PDF route, whose recovery record keeps each page's reading as it lands: a Stop asked while a page is
    /// read lets it land in the record (not held as "may have been billed") and starts no new page; the record stays.
    private static func mixedRouteWaits(root: URL, gate: Gate,
                                        check: (String, Bool, String) -> Void) async {
        let fm = FileManager.default
        let out = root.appendingPathComponent("mixed-out", isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let image = root.appendingPathComponent("mixed-image.jpg")
        let pdf = root.appendingPathComponent("mixed.pdf")
        let document = PDFDocument()
        for i in 0..<3 {
            let page = NSImage(size: NSSize(width: 60, height: 80))
            page.lockFocus()
            NSColor(white: 0.2 + 0.2 * Double(i), alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 60, height: 80).fill()
            page.unlockFocus()
            if let pdfPage = PDFPage(image: page) { document.insert(pdfPage, at: i) }
        }
        guard makeJPEG(image, shade: 0.5), let data = document.dataRepresentation(),
              (try? data.write(to: pdf)) != nil else {
            check("the mixed fixture is written", false, "")
            return
        }
        let files = [image, pdf]
        let model = LLMModel.geminiModels[0]
        let config = SessionProcessingConfig.fromProcessFilesRunStart()
        let mixed = OCRProcessor()
        mixed.taggingMode = .none
        guard mixed.beginMixedPDFJournal(
            originalFiles: files, pdfIndices: [1], outputDirectory: out, provider: .gemini, model: model,
            thinkingLevel: nil, batchMode: false, enableTagging: false, enableSegmentJSON: false,
            enableCollectionSegmentation: false, confirmCollectionIDs: false, reviewDocumentSegmentation: false,
            segmentationContext: SegmentationContext(previousTextCharCount: 0, sendPreviousImage: false,
                                                     customPrompt: nil, imageScale: 1),
            gatewayConfig: nil, localAgent: nil, runConfig: config) else {
            check("the mixed run's recovery record is started", false, "")
            return
        }
        mixed.jobs = files.map { OCRJob(sourceURL: $0) }
        mixed.isProcessing = true
        await gate.close()
        let before = await gate.count()
        let run = Task {
            await mixed.performMultiPagePDFReOCR(
                files: [(jobIndex: 1, url: pdf)], provider: .gemini, model: model, thinkingLevel: nil, apiKey: "",
                outputDirectory: out, runConfig: config, ocrOverride: { _ in
                    await gate.arrive()
                    while !(await gate.isOpen()) { try? await Task.sleep(nanoseconds: 20_000_000) }
                    return OCRResult(text: "MIXED-PAGE", classification: nil, errorMessage: nil, errorCode: nil)
                })
        }
        mixed.processingTask = run
        _ = await waitFor { await gate.count() > before }
        check("the mixed route counts as the pass a quit can wait on", mixed.ocrPhaseActive, "")
        mixed.requestStop()
        check("Stop in the mixed route waits for the page being read", mixed.stopWhenPagesSaved, mixed.statusMessage)
        await gate.release()
        await run.value
        _ = await waitFor { !mixed.isProcessing }
        let record = OCRProcessor.loadPendingMixedPDF()
        let sent = await gate.count() - before
        let firstPage = OCRProcessor.mixedPDFPageKey(index: 1, page: 0)
        check("the mixed route starts no page after Stop and keeps the one read", sent == 1
              && record?.pageResults[firstPage]?.text == "MIXED-PAGE"
              && record?.pageResults.count == 1 && record?.inFlightPage == nil,
              "\(sent) sent, \(record?.pageResults.keys.sorted() ?? []), in flight \(record?.inFlightPage ?? "none")")
        check("the mixed run stops with its record kept", !mixed.isProcessing && !mixed.drainingPages
              && !mixed.ocrPhaseActive && record != nil, "")
        _ = await waitFor { !mixed.mixedPDFCancellationUnwinding }
        check("the mixed run says the page being read was saved",
              mixed.statusMessage.hasSuffix(OCRProcessor.stoppedAfterDrainNote), mixed.statusMessage)
        OCRProcessor.deletePendingMixedPDF()
    }

    private static func waitFor(_ condition: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<3000 {   // 60 s: a loaded Mac can take seconds to send the first page; the checks are on order, not speed
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }

    private static func makeJPEG(_ url: URL, shade: Double) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
                                            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let pixels = bitmap.bitmapData else { return false }
        memset(pixels, Int32(shade * 255), bitmap.bytesPerRow * bitmap.pixelsHigh)
        guard let data = bitmap.representation(using: .jpeg, properties: [:]) else { return false }
        try? data.write(to: url)
        return FileManager.default.fileExists(atPath: url.path)
    }

    private static func finish(_ results: [String]) {
        let passed = !results.isEmpty && !results.contains { $0.hasPrefix("FAIL") }
        let report = (passed ? "ALL PASS\n" : "SOME FAILED\n") + results.joined(separator: "\n") + "\n"
        let output = ProcessInfo.processInfo.environment["RUN_QUIT_RESUME_TEST_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("archiveprocessor-run-quit-resume.txt")
        try? Data(report.utf8).write(to: output, options: .atomic)
        NSLog("%@", report)
        exit(passed ? 0 : 1)
    }
}

#endif
