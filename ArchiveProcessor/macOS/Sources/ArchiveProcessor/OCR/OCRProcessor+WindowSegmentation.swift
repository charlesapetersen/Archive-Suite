import AppKit
import PDFKit

// MARK: - The window segmenter in the pipeline (W36.seg-opt-review)
//
// For a run whose approach proposes boundaries (`SegmentationPlan.windows`), this stage replaces the per-page
// review: the box and folder photos are confirmed, the window segmenter proposes every gap, the user answers each
// flagged gap one at a time (page n beside page n+1), and then skims the whole run in the existing review sheet.
// Design: execution-plans/segmentation/04-options-build.md Part 3 §1 and §5. Nothing here writes an output file:
// the stage only sets `jobs[i].classification`, which the user has reviewed before tagging reads it.

/// A window run that could not finish: why, and whether the run can be stopped and resumed later.
struct WindowStopPrompt: Equatable {
    let message: String
    /// A pending-run manifest exists, so stopping keeps the answers so far for a later resume.
    let canResumeLater: Bool
    var title: String = defaultTitle

    static let defaultTitle = "Segmentation could not finish"
}

enum WindowStopChoice {
    /// Every gap the model did not answer is flagged, and the user checks them now.
    case checkMyself
    /// End the run here (resumable when `canResumeLater`).
    case stop
}

enum WindowStageOutcome {
    case done
    /// The run ended here: cancelled, or stopped by the user after a limit or an error.
    case stopped
}

extension OCRProcessor {
    /// Who segments a run that tags in `tagging` (the run's late output settings) with this config's approach.
    func segmentationPlan(tagging: TaggingMode, runConfig: SessionProcessingConfig?) -> SegmentationPlan {
        SegmentationPlan.resolve(tagging: tagging,
                                 approach: runConfig?.segmentationApproach ?? SegmentationApproach.stored())
    }

    /// The pages the windows cover: every file not removed, in run order, with its confirmed label kind.
    func windowStagePages(files: [URL]) -> WindowStagePages {
        var idx: [Int] = [], urls: [URL] = [], kinds: [PhotoKind?] = []
        for (i, url) in files.enumerated() where !removedSourceURLs.contains(url) && i < jobs.count {
            idx.append(i)
            urls.append(url)
            switch jobs[i].result?.classification {
            case .boxLabel: kinds.append(.box)
            case .folderLabel: kinds.append(.folder)
            default: kinds.append(nil)
            }
        }
        return WindowStagePages(fileIndices: idx, urls: urls, photoKinds: kinds)
    }

    /// The whole stage. `.stopped` means the caller ends the run where it is.
    func runWindowSegmentationStage(files: [URL], approach: SegmentationApproach,
                                    runConfig: SessionProcessingConfig?) async -> WindowStageOutcome {
        segmentationCheckSummary = nil
        // The photos are known before the windows run, as the figures were scored (Part 3 §1).
        await showBoxFolderConfirmation(files: files, runConfig: runConfig)
        guard !Task.isCancelled else { return .stopped }

        let pages = windowStagePages(files: files)
        let proposals: [GapProposal]
        switch await windowProposals(pages: pages, approach: approach) {
        case .some(let p): proposals = p
        case .none: return .stopped
        }
        guard !Task.isCancelled else { return .stopped }

        // The flagged pass.
        let rotations = pages.fileIndices.map { jobs[$0].result?.rotationDegrees ?? 0 }
        var items = FlaggedReview.items(proposals: proposals, pages: pages, rotations: rotations,
                                        prior: activePendingRun?.segmentationAnswers ?? [:])
        if !items.isEmpty {
            flaggedGapItems = items
            flaggedGapFocus = items.firstIndex { $0.answer == nil } ?? 0
            flaggedReviewApproachName = SegmentationOptionsStore.shared?.approach(approach)?.label
                ?? approach.rawValue
            statusMessage = "Check \(items.count) flagged boundar\(items.count == 1 ? "y" : "ies")."
            awaitingFlaggedReview = true
            let done = await withCheckedContinuation { continuation in
                flaggedReviewContinuation = continuation
            }
            guard done, !Task.isCancelled else { return .stopped }
            items = flaggedGapItems
            flaggedGapItems = []
            persistWindowSegmentationProgress(answers: FlaggedReview.answersByPage(items))
        }

        // Apply every boundary, then the skim.
        let classes = FlaggedReview.classifications(proposals: proposals, photoKinds: pages.photoKinds,
                                                    answers: items)
        for (k, i) in pages.fileIndices.enumerated() where k < classes.count {
            jobs[i].classification = classes[k]
            if let r = jobs[i].result {
                jobs[i].result = r.with(classification: classes[k], rotationDegrees: r.rotationDegrees)
            }
        }
        reviewCheckedFileIndices = Set(items.map { pages.fileIndices[$0.id + 1] })
        reviewSkimNote = FlaggedReview.skimNote(approach, options: SegmentationOptionsStore.shared)
        await showFullSegmentationReview(files: files, runConfig: runConfig, showsDocumentClasses: true)
        reviewCheckedFileIndices = []
        reviewSkimNote = nil
        guard !Task.isCancelled else { return .stopped }
        rebuildSegments(files: files)
        segmentationCheckSummary = FlaggedReview.summary(items)
        return .done
    }

    /// The approach's proposal for every gap, or nil when the run stops here. A usage limit or an error that no
    /// window can get past asks the user whether to check the unanswered gaps themselves or stop.
    private func windowProposals(pages: WindowStagePages, approach: SegmentationApproach) async -> [GapProposal]? {
        let spec: ApproachSpec
        do {
            guard let options = SegmentationOptionsStore.shared else { throw SegmentationOptionsError.missingResource }
            spec = try options.spec(for: approach)
        } catch {
            return await stopOrCheckAll(pages: pages, spec: nil, answered: [:],
                                        message: error.localizedDescription)
        }
        let prior = activePendingRun?.segmentationWindows ?? [:]
        // The Claude plan's meter and pauses (W36.seg-opt-subscription). Used only if Claude goes by the plan.
        let calibration = PlanCalibrationStore.load()
        let notional = SegmentationRow.planNotionalUSD(approach, options: SegmentationOptionsStore.shared,
                                                       pageCount: pages.urls.count) ?? 0
        let gate = PlanRunGate(
            pagesPerCall: spec.windowStride, folderNotionalUSD: notional,
            calibrated: calibration.fiveHourPointsPerUSD != nil,
            pageVoter: spec.voters.first { $0.provider == .anthropic }?.name) { [weak self] prompt in
                await self?.askPlanCheck(prompt) ?? false
            }
        let transport: any WindowTransport
        switch windowTransportOverride.map({ .success($0) }) ?? windowTransportFactory?(spec, gate)
            ?? WindowStageTransport.current(spec, gate: gate) {
        case .success(let t): transport = t
        case .failure(let missing):
            return await stopOrCheckAll(pages: pages, spec: spec, answered: prior, message: missing.description)
        }

        statusMessage = "Proposing boundaries for \(pages.urls.count) pages…"
        if Self.usesPlan(transport), let share = calibration.estimate(notionalUSD: notional) {
            statusMessage += " (Claude plan: \(share))"
        }
        // Keep this run's ratio for the next folder, however the windows end (usage.md step 5).
        defer {
            Task {
                let records = await gate.records
                if !records.isEmpty { PlanCalibrationStore.recordRun(records) }
            }
        }
        // A single-page PDF input was converted to a temporary JPEG for OCR; the windows read that image.
        let urls = pages.urls.map { pdfToImageMap[$0] ?? $0 }
        let texts = pages.fileIndices.map { jobs[$0].result?.text ?? "" }
        let longEdge = spec.thumbnailLongEdgePx
        let loaded: [PageInput?] = await Task.detached(priority: .userInitiated) {
            zip(urls, texts).map { Self.windowPage(url: $0, text: $1, longEdge: longEdge) }
        }.value
        if let bad = loaded.firstIndex(where: { $0 == nil }) {
            return await stopOrCheckAll(pages: pages, spec: spec, answered: prior,
                                        message: "Could not read \(pages.urls[bad].lastPathComponent) for the model.")
        }

        do {
            let result = try await WindowSegmenter(transport: transport)
                .segment(pages: loaded.compactMap { $0 }, photoKinds: pages.photoKinds, approach: spec,
                         answered: prior)
            persistWindowSegmentationProgress(windows: result.answered)
            return result.proposals
        } catch WindowSegmenterError.usageLimit(let reset, let message, let answered) {
            persistWindowSegmentationProgress(windows: answered)
            let when = reset.map { " It resets \(Self.windowResetFormatter.string(from: $0))." } ?? ""
            return await stopOrCheckAll(pages: pages, spec: spec, answered: answered,
                                        message: "The model's usage limit was reached.\(when) \(message.suffix(200))")
        } catch WindowSegmenterError.paused(let reset, let message, let answered) {
            persistWindowSegmentationProgress(windows: answered)
            let when = reset.map { " It resets \(Self.windowResetFormatter.string(from: $0))." } ?? ""
            return await stopOrCheckAll(pages: pages, spec: spec, answered: answered, message: message + when,
                                        title: "Segmentation paused")
        } catch WindowSegmenterError.fatal(let message, let answered) {
            persistWindowSegmentationProgress(windows: answered)
            return await stopOrCheckAll(pages: pages, spec: spec, answered: answered, message: message)
        } catch {
            if Task.isCancelled || error is CancellationError { return nil }
            return await stopOrCheckAll(pages: pages, spec: spec, answered: prior, message: "\(error)")
        }
    }

    /// One page for the windows. A pre-OCRed input is a PDF, whose first page is rendered at the long edge.
    nonisolated static func windowPage(url: URL, text: String, longEdge: Int) -> PageInput? {
        guard url.pathExtension.lowercased() == "pdf" else {
            return PageInput.load(imageURL: url, text: text, longEdge: longEdge)
        }
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let box = page.bounds(for: .mediaBox)
        let scale = CGFloat(longEdge) / max(box.width, box.height, 1)
        let image = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return PageInput(jpeg: jpeg, text: text)
    }

    private static let windowResetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    /// Ask the user (§2 Failure): check every unanswered gap now, or stop. Stopping keeps the answers so far in
    /// the run's manifest, so a resume asks the model only for the rest.
    private func stopOrCheckAll(pages: WindowStagePages, spec: ApproachSpec?,
                                answered: [WindowKey: WindowAnswer], message: String,
                                title: String = WindowStopPrompt.defaultTitle) async -> [GapProposal]? {
        // A Stop pressed during the last suspension has already released the continuations: arming a new one
        // now would show a stale prompt and leak it.
        guard !Task.isCancelled else { return nil }
        let canResume = activePendingRun != nil
        windowStopPrompt = WindowStopPrompt(message: message, canResumeLater: canResume, title: title)
        let choice = await withCheckedContinuation { continuation in
            windowStopContinuation = continuation
        }
        windowStopPrompt = nil
        guard !Task.isCancelled else { return nil }
        switch choice {
        case .checkMyself:
            return Self.partialProposals(pages: pages, spec: spec, answered: answered)
        case .stop:
            stopRunAfterWindowStage(message: message, resumable: canResume)
            return nil
        }
    }

    /// The proposals the answered windows make; every gap no window answered is flagged with confidence 0.
    nonisolated static func partialProposals(pages: WindowStagePages, spec: ApproachSpec?,
                                             answered: [WindowKey: WindowAnswer]) -> [GapProposal] {
        let n = pages.urls.count
        guard let spec else {
            return WindowCombiner.proposals(photoKinds: pages.photoKinds, voters: [Array(repeating: nil, count: max(0, n - 1))],
                                            rule: .min, level: 1)
        }
        let windows = WindowLayout.windows(pageCount: n, pages: spec.windowPages, stride: spec.windowStride)
        let verdicts = spec.voters.map { v in
            WindowCombiner.voterVerdicts(pageCount: n, windows: windows, answers: Dictionary(
                uniqueKeysWithValues: windows.compactMap { w in
                    answered[WindowKey(voter: v.name, pages: n, start: w.lowerBound, end: w.upperBound)].map { (w, $0) }
                }))
        }
        return WindowCombiner.proposals(photoKinds: pages.photoKinds, voters: verdicts, rule: spec.rule,
                                        level: spec.level)
    }

    /// Called by the stop prompt.
    func answerWindowStop(_ choice: WindowStopChoice) {
        windowStopContinuation?.resume(returning: choice)
        windowStopContinuation = nil
    }

    /// The plan route's first measurement on this account (usage.md step 3): show the folder's share and ask
    /// whether to go on. False when the run is cancelled meanwhile.
    func askPlanCheck(_ prompt: PlanCheckPrompt) async -> Bool {
        // The gate cancels this call when the window waiting on it is cancelled (the run stopped), so a dialog
        // already up is taken down, and one not yet shown never is.
        guard !Task.isCancelled else { return false }
        planCheckContinuation?.resume(returning: false)
        planCheckPrompt = prompt
        let goOn = await withTaskCancellationHandler {
            await withCheckedContinuation { planCheckContinuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.answerPlanCheck(goOn: false) }
        }
        planCheckPrompt = nil
        return goOn
    }

    /// Called by the plan-check alert.
    func answerPlanCheck(goOn: Bool) {
        planCheckContinuation?.resume(returning: goOn)
        planCheckContinuation = nil
    }

    /// Whether any of a run's Claude windows go by the plan.
    nonisolated static func usesPlan(_ t: any WindowTransport) -> Bool {
        if t is LocalAgentWindowTransport { return true }
        return (t as? RoutingWindowTransport)?.routes.values.contains { $0 is LocalAgentWindowTransport } ?? false
    }

    /// Called by the flagged pass's Done (only enabled when every gap is answered).
    func confirmFlaggedReview() {
        guard FlaggedReview.isComplete(flaggedGapItems) else { return }
        awaitingFlaggedReview = false
        flaggedReviewContinuation?.resume(returning: true)
        flaggedReviewContinuation = nil
    }

    /// Resume whichever stage continuation is waiting, as the run is cancelled (`cancel()`).
    func releaseWindowStageContinuations() {
        awaitingFlaggedReview = false
        flaggedReviewContinuation?.resume(returning: false)
        flaggedReviewContinuation = nil
        windowStopPrompt = nil
        windowStopContinuation?.resume(returning: .stop)
        windowStopContinuation = nil
        planCheckPrompt = nil
        planCheckContinuation?.resume(returning: false)
        planCheckContinuation = nil
        segmentationCheckSummary = nil
    }

    /// End the run after the user chose Stop: the OCR is done and saved, so a pending-run manifest stays on disk
    /// for the Resume control.
    private func stopRunAfterWindowStage(message: String, resumable: Bool) {
        // Cancel the run's task so every caller's cancellation guard ends it here (the pre-OCRed path returns to
        // a success tail that only those guards stop), and no completion is recorded.
        processingTask?.cancel()
        processingTask = nil
        activeRunHistory = nil
        activePendingRun = nil
        isProcessing = false
        cleanupTempFiles()
        checkForPendingBatch()
        statusMessage = "Stopped before segmentation: \(message)"
            + (resumable ? " Resume the run to continue where it stopped." : "")
    }
}

#if DEBUG
extension OCRProcessor {
    /// UI test only (`-APUITestFlaggedReview`): the flagged pass over two synthetic gaps among three drawn pages
    /// in this app's own temporary directory. No run, OCR, model call, manifest or output is involved; the
    /// answers are shown in `uiTestFlaggedResult` once Done is pressed.
    func _uiTestShowFlaggedReview() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("APUITestFlagged-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let urls = (1...3).map { n -> URL in
            let url = dir.appendingPathComponent("page-\(n).png")
            let image = NSImage(size: NSSize(width: 300, height: 400), flipped: false) { r in
                NSColor.white.setFill(); r.fill()
                ("Synthetic page \(n)" as NSString).draw(at: NSPoint(x: 40, y: 200),
                                                          withAttributes: [.font: NSFont.systemFont(ofSize: 28)])
                return true
            }
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            return url
        }
        flaggedGapItems = [
            FlaggedGapItem(id: 0, leftURL: urls[0], rightURL: urls[1], leftRotation: 0, rightRotation: 0,
                           proposal: .continue, confidence: 0.6, cue: "the letter seems to go on"),
            FlaggedGapItem(id: 1, leftURL: urls[1], rightURL: urls[2], leftRotation: 0, rightRotation: 0,
                           proposal: .new, confidence: 0.8, cue: "a new letterhead"),
        ]
        flaggedGapFocus = 0
        flaggedReviewApproachName = "Claude"
        awaitingFlaggedReview = true
        Task { @MainActor in
            let done = await withCheckedContinuation { flaggedReviewContinuation = $0 }
            uiTestFlaggedResult = "flagged done=\(done) "
                + flaggedGapItems.map { $0.answer?.rawValue ?? "-" }.joined(separator: ",")
        }
    }
}
#endif
