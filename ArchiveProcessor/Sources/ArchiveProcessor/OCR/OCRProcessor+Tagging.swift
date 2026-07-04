import Foundation
import UserNotifications

extension OCRProcessor {
    /// Applies Red/Purple color tags to box/folder label PDFs when full LLM tagging
    /// is disabled (or when passing source tags through). When automatic tagging is enabled
    /// these tags are already applied by the normal tagging pass, so this is a no-op.
    func applyBoxFolderLabelTags(enableTagging: Bool) {
        guard !enableTagging || passSourceTags else { return }
        applyBoxFolderLabelTagsUnconditionally()
    }
    /// Applies Red/Purple color tags to every box/folder label output PDF, unconditionally.
    /// Used by manual tagging modes, which don't run the automatic tagging pass.
    private func applyBoxFolderLabelTagsUnconditionally() {
        for job in jobs {
            guard let classification = job.result?.classification else { continue }
            let tags: GeneratedTags
            switch classification {
            case .boxLabel: tags = GeneratedTags(subjectTags: ["Box"], colorTag: "Red")
            case .folderLabel: tags = GeneratedTags(subjectTags: ["Folder"], colorTag: "Purple")
            default: continue
            }
            if let outputPDF = outputURLMap[job.sourceURL] {
                try? MacOSTagger.applyTags(tags, to: outputPDF)
            }
        }
    }
    /// Phone-supplied year for the file at `index`, as a "YYYY" tag; nil if none.
    private func phoneYearTag(at index: Int) -> String? {
        guard index >= 0, index < preGroupedYears.count, let y = preGroupedYears[index] else { return nil }
        return String(y)
    }
    /// Phone-supplied month for the file at `index`, as an "MM Month" tag (e.g. "03 March"); nil if none.
    private func phoneMonthTag(at index: Int) -> String? {
        guard index >= 0, index < preGroupedMonths.count,
              let m = preGroupedMonths[index], (1...12).contains(m) else { return nil }
        return String(format: "%02d %@", m, Self.englishMonthNames[m - 1])
    }
    /// Live Capture: layer each page's phone-set priority ("P10"…"P7") onto whatever the tagging
    /// phase applied. macOS tag application replaces, so read → append → re-apply; also record it in
    /// the job's appliedTags so document merging carries it. No-op outside a pre-grouped run.
    func applyCapturePriorityTags() {
        guard !preGroupedPriorities.isEmpty else { return }
        for i in jobs.indices where i < preGroupedPriorities.count {
            guard let raw = preGroupedPriorities[i]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let outputPDF = outputURLMap[jobs[i].sourceURL] else { continue }
            var tags = MacOSTagger.readTags(from: outputPDF)
            if !tags.contains(raw) {
                tags.append(raw)
                try? MacOSTagger.applyTags(tags, to: outputPDF)
            }
            if !jobs[i].appliedTags.contains(raw) { jobs[i].appliedTags.append(raw) }
        }
    }
    /// Live Capture dual output: write each page's original image next to its PDF (same base name),
    /// tagged identically, so the final folder holds BOTH the image and the PDF. Runs before merge/
    /// organization so `outputURLMap` is still per-page; `organizeOutput` moves the sibling image too.
    func exportOriginalImages() async {
        guard exportOriginals else { return }
        let exportedMB = Self.exportedImageMB
        // Snapshot the work on the main actor… The exported image is always a .jpg sized toward the
        // exported-image target (independent of the source/camera size).
        let work: [(src: URL, img: URL, pdf: URL, rot: Int)] = jobs.compactMap { job in
            guard let pdfURL = outputURLMap[job.sourceURL],
                  FileManager.default.fileExists(atPath: job.sourceURL.path) else { return nil }
            // For PDF inputs, export from the converted temp JPEG (the same page image the PDF embeds),
            // not the raw .pdf — matching every PDFGenerator call site.
            let src = pdfToImageMap[job.sourceURL] ?? job.sourceURL
            // Snapshot the final (post-review) rotation so the exported .jpg matches the rotated PDF.
            return (src: src, img: pdfURL.deletingPathExtension().appendingPathExtension("jpg"), pdf: pdfURL,
                    rot: job.result?.rotationDegrees ?? 0)
        }
        guard !work.isEmpty else { return }
        // …then encode the sized JPEGs + mirror the PDF's tags OFF the main thread, so the UI never
        // stalls on large files. writeSizedJPEG copies already-small unrotated JPEGs byte-for-byte.
        await Task.detached(priority: .utility) {
            for w in work {
                guard ImageEncoding.writeSizedJPEG(from: w.src, to: w.img, targetMB: exportedMB, rotationDegrees: w.rot) else { continue }
                // Mirror the PDF's tags onto the image (applyTags re-stamps the trailing "Unread"
                // in real-tagging modes, so the image always matches the PDF, ending with "Unread").
                let tags = MacOSTagger.readTags(from: w.pdf)
                try? MacOSTagger.applyTags(tags, to: w.img)
            }
        }.value
    }
    /// Automatic (LLM) tagging with the redo-review loop. Extracted so the standard and
    /// pre-OCRed pipelines share one implementation.
    func performAutomaticTaggingWithReview(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool,
        files: [URL]
    ) async {
        var shouldRedoTagging = true
        while shouldRedoTagging {
            statusMessage = "Found \(segments.count) segments. Generating tags…"

            await performTaggingPhase(
                provider: provider,
                model: model,
                thinkingLevel: thinkingLevel,
                apiKey: apiKey,
                outputDirectory: outputDirectory,
                enableSegmentJSON: enableSegmentJSON
            )

            guard !Task.isCancelled else { return }

            // Interactive Review Point 2: Pause for final review after tagging
            statusMessage = "Review tags and segmentation. Click Complete to finalize, or Redo to re-tag."
            isProcessing = false
            awaitingFinalReview = true

            let action: FinalReviewAction = await withCheckedContinuation { continuation in
                finalReviewContinuation = continuation
            }

            guard !Task.isCancelled else { return }
            isProcessing = true

            switch action {
            case .complete:
                shouldRedoTagging = false
            case .redoTagging:
                rebuildSegments(files: files)
                for i in jobs.indices { jobs[i].appliedTags = [] }
            }
        }
    }
    /// Manual (human-in-the-loop) tagging. Presents each non-box/folder segment sequentially
    /// for the user to enter subject tags (and, in `.human` mode, the date). In `.autoDate`
    /// mode the date is prefetched from the LLM while the user tags, so they never wait on
    /// the network. Box/folder segments still receive their Red/Purple color tags.
    func performManualTaggingPhase(
        mode: TaggingMode,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool
    ) async {
        // Apply Red/Purple color tags to box/folder segments (they aren't manually tagged).
        applyBoxFolderLabelTagsUnconditionally()

        // Build one manual-tag entry per taggable (non-box/folder) segment.
        func rotation(for url: URL) -> Int {
            jobs.first(where: { $0.sourceURL == url })?.result?.rotationDegrees ?? 0
        }
        var manual: [ManualTagSegment] = []
        for (i, seg) in segments.enumerated() where !seg.isBox && !seg.isFolder {
            var images: [ManualTagImage] = []
            // Context: the nearest preceding box/folder label (shown first, never tagged).
            if let ctxSeg = segments[0..<i].last(where: { $0.isBox || $0.isFolder }),
               let ctxURL = ctxSeg.pdfURLs.first {
                images.append(ManualTagImage(url: ctxURL, rotationDegrees: rotation(for: ctxURL), isContext: true))
            }
            for url in seg.pdfURLs {
                images.append(ManualTagImage(url: url, rotationDegrees: rotation(for: url), isContext: false))
            }
            // Pre-fill the phone's date (Live Capture); when present, skip the LLM date prefetch.
            let phoneFileIdx = seg.pdfURLs.first.flatMap { url in jobs.firstIndex(where: { $0.sourceURL == url }) }
            let phoneYear = phoneFileIdx.flatMap { phoneYearTag(at: $0) }
            let phoneMonth = phoneFileIdx.flatMap { phoneMonthTag(at: $0) }
            manual.append(ManualTagSegment(
                segmentIndex: i,
                images: images,
                year: phoneYear ?? "",
                month: phoneMonth ?? "",
                subjectTags: ["Unread"],
                dateLoading: mode == .autoDate && phoneYear == nil && phoneMonth == nil
            ))
        }
        guard !manual.isEmpty else { return }

        manualTagSegments = manual
        currentManualIndex = 0

        // Prefetch dates for .autoDate while the user works (in-order, so early segments fill first).
        var dateTask: Task<Void, Never>? = nil
        if mode == .autoDate {
            dateTask = Task { [weak self] in
                await self?.prefetchManualDates(
                    provider: provider, model: model,
                    thinkingLevel: thinkingLevel, apiKey: apiKey
                )
            }
        }

        statusMessage = "Manual tagging: \(manual.count) segment\(manual.count == 1 ? "" : "s")."
        isProcessing = false
        awaitingManualTagging = true

        await withCheckedContinuation { continuation in
            manualTaggingContinuation = continuation
        }

        dateTask?.cancel()
        guard !Task.isCancelled else { return }
        isProcessing = true

        // Apply the user's tags to each segment's output PDF(s) and write JSON.
        for m in manualTagSegments where m.segmentIndex < segments.count {
            let seg = segments[m.segmentIndex]
            var tags = GeneratedTags()
            tags.year = m.year.isEmpty ? nil : m.year
            tags.month = m.month.isEmpty ? nil : m.month
            tags.day = m.day.isEmpty ? nil : m.day
            tags.dateUncertain = m.dateUncertain
            tags.subjectTags = m.subjectTags

            for sourceURL in seg.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    try? MacOSTagger.applyTags(tags, to: outputPDF)
                }
                if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                    jobs[jobIndex].appliedTags = tags.allTags
                }
            }
            if enableSegmentJSON {
                writeSegmentJSON(segment: seg, tags: tags, outputDirectory: outputDirectory)
            }
        }
    }
    /// Sequentially prefetch LLM date estimates for the manual-tag segments, filling any
    /// date fields the user hasn't already edited.
    private func prefetchManualDates(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String
    ) async {
        let generator = TagGenerator()
        // Gather segments still needing a date (main actor); skip already-dated ones (incl. Live
        // Capture pre-fills).
        var work: [(idx: Int, segment: DocumentSegment, nearby: [DocumentSegment])] = []
        for idx in manualTagSegments.indices {
            let segIndex = manualTagSegments[idx].segmentIndex
            guard segIndex < segments.count else { continue }
            if !manualTagSegments[idx].year.isEmpty {
                manualTagSegments[idx].dateLoading = false
                continue
            }
            let nearby = Array(
                segments[max(0, segIndex - 3)..<segIndex]
                + segments[min(segIndex + 1, segments.count)..<min(segIndex + 4, segments.count)]
            )
            work.append((idx, segments[segIndex], nearby))
        }
        guard !work.isEmpty else { return }
        let gateway = currentGateway
        let maxConcurrent = min(6, work.count)

        // Fetch dates concurrently (bounded), skipping thinking, and apply each result on the main
        // actor as it arrives (only filling fields the user hasn't already set).
        await withTaskGroup(of: (Int, GeneratedTags).self) { group in
            var next = 0
            while next < maxConcurrent {
                let w = work[next]
                group.addTask {
                    let date = await generator.generateDateOnly(
                        for: w.segment, nearbySegments: w.nearby,
                        provider: provider, model: model, thinkingLevel: nil,
                        apiKey: apiKey, gatewayConfig: gateway
                    )
                    return (w.idx, date)
                }
                next += 1
            }
            for await (idx, date) in group {
                if Task.isCancelled { break }
                if idx < manualTagSegments.count {
                    if manualTagSegments[idx].year.isEmpty { manualTagSegments[idx].year = date.year ?? "" }
                    if manualTagSegments[idx].month.isEmpty { manualTagSegments[idx].month = date.month ?? "" }
                    if manualTagSegments[idx].day.isEmpty { manualTagSegments[idx].day = date.day ?? "" }
                    manualTagSegments[idx].dateUncertain = date.dateUncertain
                    manualTagSegments[idx].dateLoading = false
                }
                if next < work.count {
                    let w = work[next]
                    group.addTask {
                        let date = await generator.generateDateOnly(
                            for: w.segment, nearbySegments: w.nearby,
                            provider: provider, model: model, thinkingLevel: nil,
                            apiKey: apiKey, gatewayConfig: gateway
                        )
                        return (w.idx, date)
                    }
                    next += 1
                }
            }
        }
    }
    /// UI: advance to the next manual-tag segment, or finish if on the last one.
    func advanceManualSegment() {
        if currentManualIndex < manualTagSegments.count - 1 {
            currentManualIndex += 1
        } else {
            finishManualTagging()
        }
    }
    /// UI: go back to the previous manual-tag segment.
    func previousManualSegment() {
        if currentManualIndex > 0 { currentManualIndex -= 1 }
    }
    /// UI: finish manual tagging and resume the pipeline.
    func finishManualTagging() {
        awaitingManualTagging = false
        manualTaggingContinuation?.resume()
        manualTaggingContinuation = nil
    }
    /// Present the progressive manual segmentation + tagging window (human / autoDateManualSeg).
    /// The user reviews rotation + box/folder, walks the photos in order, marks where each document
    /// segment ends and tags it (the tagged pages then drop out of the viewer). On Finish, the
    /// identified segments are translated back into job classifications, corrected rotations are
    /// baked into the output PDFs, and each segment's tags are applied.
    func performManualSegmentAndTag(
        autoDate: Bool,
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool,
        preOCRed: Bool,
        files: [URL]
    ) async {
        // Capture params for on-demand LLM date fetching from the UI.
        manualSegAutoDate = autoDate
        manualSegProvider = provider
        manualSegModel = model
        manualSegThinking = thinkingLevel
        manualSegApiKey = apiKey
        manualSegPreOCRed = preOCRed

        // Build the ordered image list (excluding already-removed files). Kind + rotation seed from
        // the OCR classifications; both are user-editable in the UI.
        var images: [ManualSegImage] = []
        for (i, url) in files.enumerated() {
            guard !removedSourceURLs.contains(url), i < jobs.count else { continue }
            let cls = jobs[i].result?.classification
            let kind: ManualPhotoKind = cls == .boxLabel ? .box : (cls == .folderLabel ? .folder : .document)
            images.append(ManualSegImage(
                fileIndex: i,
                url: url,
                rotationDegrees: jobs[i].result?.rotationDegrees ?? 0,
                kind: kind
            ))
        }
        guard !images.isEmpty else { return }

        manualSegImages = images
        manualSegConsumed = []
        manualSegRemoved = []
        manualSegCompleted = []
        manualSegTaggingRange = nil
        manualSegDraftTags = SegmentTagData()
        manualSegDateFetching = false
        manualSegFocus = manualSegPendingStart ?? 0

        statusMessage = "Manual segmentation & tagging: \(images.count) image\(images.count == 1 ? "" : "s")."
        isProcessing = false
        awaitingManualSegTag = true

        await withCheckedContinuation { continuation in
            manualSegContinuation = continuation
        }

        guard !Task.isCancelled else { return }
        isProcessing = true

        // (a) Removals: drop flagged photos from output, tagging, and segmentation.
        for idx in manualSegRemoved where idx < manualSegImages.count {
            let fileIndex = manualSegImages[idx].fileIndex
            guard fileIndex < jobs.count else { continue }
            let sourceURL = jobs[fileIndex].sourceURL
            removedSourceURLs.insert(sourceURL)
            if let outputURL = outputURLMap[sourceURL] {
                try? FileManager.default.removeItem(at: outputURL)
                let jsonURL = outputURL.deletingPathExtension().appendingPathExtension("json")
                try? FileManager.default.removeItem(at: jsonURL)
                outputURLMap[sourceURL] = nil
            }
            jobs[fileIndex].status = .removed
        }

        // (b) Rotation: bake any corrected rotation into the output PDF by regenerating it. Skipped
        // for pre-OCRed input, where the "output" IS the user's original source PDF (regen would
        // overwrite it). Must run before merge (which deletes per-page PDFs) and before tag apply
        // (regen overwrites the PDF, which would clobber freshly-applied Finder tags).
        if !preOCRed, let model = currentModel {
            for idx in manualSegImages.indices where !manualSegRemoved.contains(idx) {
                let img = manualSegImages[idx]
                let fileIndex = img.fileIndex
                guard fileIndex < jobs.count, let existing = jobs[fileIndex].result,
                      img.rotationDegrees != existing.rotationDegrees else { continue }
                let updated = OCRResult(text: existing.text, classification: existing.classification,
                                        rotationDegrees: img.rotationDegrees,
                                        errorMessage: existing.errorMessage, errorCode: nil)
                jobs[fileIndex].result = updated
                if let outputURL = outputURLMap[jobs[fileIndex].sourceURL] {
                    let imageURL = pdfToImageMap[img.url] ?? img.url
                    try? PDFGenerator().generate(
                        imageURL: imageURL, result: updated, model: model, outputURL: outputURL,
                        originalFileName: jobs[fileIndex].sourceURL.lastPathComponent,
                        gatewayDisplayName: currentGateway?.displayName,
                        pdfImageMB: Self.pdfImageMB
                    )
                }
            }
        }

        // (c) Write classifications from the user's kinds + completed-segment membership.
        var startArrayIndices = Set<Int>()
        for seg in manualSegCompleted { if let first = seg.indices.first { startArrayIndices.insert(first) } }
        for idx in manualSegImages.indices where !manualSegRemoved.contains(idx) {
            let img = manualSegImages[idx]
            let fileIndex = img.fileIndex
            guard fileIndex < jobs.count else { continue }
            let newCls: DocumentClassification
            switch img.kind {
            case .box: newCls = .boxLabel
            case .folder: newCls = .folderLabel
            case .document: newCls = startArrayIndices.contains(idx) ? .documentStart : .documentContinuation
            }
            jobs[fileIndex].classification = newCls
            if let r = jobs[fileIndex].result {
                jobs[fileIndex].result = OCRResult(text: r.text, classification: newCls,
                                                   rotationDegrees: r.rotationDegrees,
                                                   errorMessage: r.errorMessage, errorCode: nil)
            }
        }

        // (d) Rebuild segments from the corrected classifications; apply box/folder color tags.
        rebuildSegments(files: files)
        applyBoxFolderLabelTagsUnconditionally()

        // (e) Apply each identified segment's tags to its output PDFs, keyed by the segment's
        // first-page URL (a stable key that survives consumption).
        var tagsByFirstURL: [URL: SegmentTagData] = [:]
        for seg in manualSegCompleted {
            guard let first = seg.indices.first, first < manualSegImages.count else { continue }
            tagsByFirstURL[manualSegImages[first].url] = seg.tags
        }

        for seg in segments where !seg.isBox && !seg.isFolder {
            guard let firstURL = seg.pdfURLs.first else { continue }
            let data = tagsByFirstURL[firstURL] ?? SegmentTagData()
            var gtags = GeneratedTags()
            gtags.year = data.year.isEmpty ? nil : data.year
            gtags.month = data.month.isEmpty ? nil : data.month
            gtags.day = data.day.isEmpty ? nil : data.day
            gtags.dateUncertain = data.dateUncertain
            gtags.subjectTags = data.subjectTags

            for sourceURL in seg.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    try? MacOSTagger.applyTags(gtags, to: outputPDF)
                }
                if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                    jobs[jobIndex].appliedTags = gtags.allTags
                }
            }
            if enableSegmentJSON {
                writeSegmentJSON(segment: seg, tags: gtags, outputDirectory: outputDirectory)
            }
        }
    }
    /// First array index that is an un-consumed, un-removed document — the start of the pending segment.
    var manualSegPendingStart: Int? {
        manualSegImages.indices.first {
            manualSegImages[$0].kind == .document && !manualSegConsumed.contains($0) && !manualSegRemoved.contains($0)
        }
    }
    /// The last index of the contiguous document run beginning at `start` (stops at a box/folder or a
    /// consumed image; removed images are skipped transparently).
    func manualSegRunEnd(from start: Int) -> Int {
        var end = start
        var k = start
        while k < manualSegImages.count {
            if manualSegConsumed.contains(k) { break }
            if manualSegImages[k].kind != .document { break }
            if !manualSegRemoved.contains(k) { end = k }
            k += 1
        }
        return end
    }
    /// The last index of the pending segment given the current focus (clamped into the run).
    var manualSegPendingEnd: Int? {
        guard let s = manualSegPendingStart else { return nil }
        return min(max(manualSegFocus, s), manualSegRunEnd(from: s))
    }
    /// The array-index range currently highlighted as the pending segment (nil while none).
    var manualSegPendingRange: ClosedRange<Int>? {
        guard let s = manualSegPendingStart, let e = manualSegPendingEnd, s <= e else { return nil }
        return s...e
    }
    /// Number of document photos still awaiting tagging.
    var manualSegRemainingDocCount: Int {
        manualSegImages.indices.filter {
            manualSegImages[$0].kind == .document && !manualSegConsumed.contains($0) && !manualSegRemoved.contains($0)
        }.count
    }
    /// Move the viewer focus to the next/previous non-consumed photo.
    func manualSegAdvanceFocus(_ delta: Int) {
        guard !manualSegImages.isEmpty, delta != 0 else { return }
        var i = manualSegFocus + delta
        while i >= 0 && i < manualSegImages.count {
            if !manualSegConsumed.contains(i) { manualSegFocus = i; return }
            i += delta
        }
    }
    /// Set the focused photo's kind (Box / Folder / Document). No-op on consumed photos.
    func manualSegSetKind(_ kind: ManualPhotoKind, at idx: Int) {
        guard idx >= 0, idx < manualSegImages.count, !manualSegConsumed.contains(idx) else { return }
        manualSegImages[idx].kind = kind
    }
    /// Toggle whether the focused photo is flagged for removal (file ops applied at Finish).
    func manualSegToggleRemoved(at idx: Int) {
        guard idx >= 0, idx < manualSegImages.count, !manualSegConsumed.contains(idx) else { return }
        if manualSegRemoved.contains(idx) { manualSegRemoved.remove(idx) } else { manualSegRemoved.insert(idx) }
    }
    /// Open the tag card for the current pending segment, seeding the phone date (Live Capture).
    func manualSegEndAndTag() {
        guard manualSegTaggingRange == nil, let range = manualSegPendingRange else { return }
        var seed = SegmentTagData()
        let firstFileIndex = manualSegImages[range.lowerBound].fileIndex
        if let y = phoneYearTag(at: firstFileIndex) { seed.year = y }
        if let mo = phoneMonthTag(at: firstFileIndex) { seed.month = mo }
        manualSegDraftTags = seed
        manualSegTaggingRange = range
    }
    /// Dismiss the tag card without committing (back to browsing to adjust the segment end).
    func manualSegCancelTagging() {
        manualSegTaggingRange = nil
        manualSegDateFetching = false
    }
    /// Commit the pending segment with the drafted tags — its document pages are consumed (drop out).
    func manualSegCommitPendingSegment() {
        guard let range = manualSegTaggingRange else { return }
        let indices = range.filter { manualSegImages[$0].kind == .document && !manualSegRemoved.contains($0) }
        manualSegTaggingRange = nil
        manualSegDateFetching = false
        guard !indices.isEmpty else { return }
        manualSegCompleted.append(CompletedManualSegment(indices: indices, tags: manualSegDraftTags))
        manualSegConsumed.formUnion(indices)
        manualSegDraftTags = SegmentTagData()
        if let next = manualSegPendingStart {
            manualSegFocus = next
        } else if let firstVisible = manualSegImages.indices.first(where: { !manualSegConsumed.contains($0) }) {
            manualSegFocus = firstVisible
        }
    }
    func confirmManualSegTag() {
        awaitingManualSegTag = false
        manualSegContinuation?.resume()
        manualSegContinuation = nil
    }
    /// UI (autoDateManualSeg mode): fetch the LLM date for the pending segment's pages and fill any
    /// empty date fields in the draft. Idempotent — skips if a date is present or a fetch is in flight.
    func fetchManualSegDate(forIndices indices: [Int]) async {
        guard manualSegAutoDate, let model = manualSegModel else { return }
        guard manualSegDraftTags.year.isEmpty, !manualSegDateFetching else { return }

        var urls: [URL] = []
        var texts: [String] = []
        for i in indices where i >= 0 && i < manualSegImages.count && manualSegImages[i].kind == .document {
            let url = manualSegImages[i].url
            urls.append(url)
            texts.append(jobs.first { $0.sourceURL == url }?.result?.text ?? "")
        }
        guard !urls.isEmpty else { return }

        manualSegDateFetching = true
        let segment = DocumentSegment(pdfURLs: urls, texts: texts)
        let date = await TagGenerator().generateDateOnly(
            for: segment, nearbySegments: [],
            provider: manualSegProvider, model: model,
            thinkingLevel: manualSegThinking, apiKey: manualSegApiKey,
            gatewayConfig: currentGateway
        )
        manualSegDateFetching = false

        guard !Task.isCancelled else { return }
        if manualSegDraftTags.year.isEmpty { manualSegDraftTags.year = date.year ?? "" }
        if manualSegDraftTags.month.isEmpty { manualSegDraftTags.month = date.month ?? "" }
        if manualSegDraftTags.day.isEmpty { manualSegDraftTags.day = date.day ?? "" }
        manualSegDraftTags.dateUncertain = date.dateUncertain
    }
    func performTaggingPhase(
        provider: LLMProvider,
        model: LLMModel,
        thinkingLevel: ThinkingLevel?,
        apiKey: String,
        outputDirectory: URL,
        enableSegmentJSON: Bool = true
    ) async {
        let generator = TagGenerator()
        let snapshot = segments
        let total = snapshot.count
        guard total > 0 else { return }
        // Capture immutable inputs for the concurrent tasks.
        let vocabulary = tagVocabulary
        let gateway = currentGateway
        let maxConcurrent = min(6, total)

        // Precompute neighbor context per segment on the main actor, so the concurrent tasks capture
        // only immutable, Sendable inputs.
        let nearbyBySeg: [[DocumentSegment]] = (0..<total).map { i in
            Array(snapshot[max(0, i - 3)..<i] + snapshot[min(i + 1, total)..<min(i + 4, total)])
        }
        // Subjects the Mac operator entered during Live Capture (per segment). Non-empty → apply
        // directly and skip the LLM tag call for that segment.
        let macSubjectsBySeg: [[String]] = snapshot.map { seg in
            guard let firstURL = seg.pdfURLs.first,
                  let fileIdx = jobs.firstIndex(where: { $0.sourceURL == firstURL }),
                  fileIdx < preGroupedSubjects.count else { return [] }
            return preGroupedSubjects[fileIdx]
        }

        // Tag segments concurrently (bounded pool) instead of one-at-a-time. Each call is small,
        // text-only, and independent, so overlapping the network round-trips is a big speedup.
        // Tagging is a simple text→JSON task, so we skip thinking (`thinkingLevel: nil`).
        var completed = 0
        await withTaskGroup(of: (Int, GeneratedTags).self) { group in
            var next = 0
            while next < maxConcurrent {
                let i = next
                group.addTask {
                    if !macSubjectsBySeg[i].isEmpty {
                        return (i, GeneratedTags(subjectTags: macSubjectsBySeg[i]))   // Mac-tagged → no LLM
                    }
                    let tags = await generator.generateTags(
                        for: snapshot[i], nearbySegments: nearbyBySeg[i],
                        provider: provider, model: model, thinkingLevel: nil,
                        apiKey: apiKey, vocabulary: vocabulary, gatewayConfig: gateway
                    )
                    return (i, tags)
                }
                next += 1
            }
            for await (i, rawTags) in group {
                if Task.isCancelled { break }
                applyGeneratedTags(rawTags, toSegmentAt: i, in: snapshot,
                                   enableSegmentJSON: enableSegmentJSON, outputDirectory: outputDirectory)
                completed += 1
                progress = 0.7 + (Double(completed) / Double(total)) * 0.3
                statusMessage = "Tagging \(completed)/\(total)…"
                if next < total {
                    let j = next
                    group.addTask {
                        if !macSubjectsBySeg[j].isEmpty {
                            return (j, GeneratedTags(subjectTags: macSubjectsBySeg[j]))   // Mac-tagged → no LLM
                        }
                        let tags = await generator.generateTags(
                            for: snapshot[j], nearbySegments: nearbyBySeg[j],
                            provider: provider, model: model, thinkingLevel: nil,
                            apiKey: apiKey, vocabulary: vocabulary, gatewayConfig: gateway
                        )
                        return (j, tags)
                    }
                    next += 1
                }
            }
        }
    }
    /// Apply generated tags to one segment's output PDFs, layering the Live Capture phone date on top
    /// and writing the segment JSON. Runs on the main actor (called from the tagging task group).
    private func applyGeneratedTags(_ rawTags: GeneratedTags, toSegmentAt i: Int, in snapshot: [DocumentSegment],
                                    enableSegmentJSON: Bool, outputDirectory: URL) {
        guard i < snapshot.count else { return }
        let segment = snapshot[i]
        var tags = rawTags
        // Live Capture: the phone's in-the-room date wins over the LLM's inferred date.
        if let firstURL = segment.pdfURLs.first,
           let fileIdx = jobs.firstIndex(where: { $0.sourceURL == firstURL }) {
            if let y = phoneYearTag(at: fileIdx) { tags.year = y; tags.dateUncertain = false }
            if let mo = phoneMonthTag(at: fileIdx) { tags.month = mo }
        }
        for sourceURL in segment.pdfURLs {
            if let outputPDF = outputURLMap[sourceURL] {
                try? MacOSTagger.applyTags(tags, to: outputPDF)
            }
            if let jobIndex = jobs.firstIndex(where: { $0.sourceURL == sourceURL }) {
                jobs[jobIndex].appliedTags = tags.allTags
            }
        }
        if enableSegmentJSON && !segment.isBox && !segment.isFolder {
            writeSegmentJSON(segment: segment, tags: tags, outputDirectory: outputDirectory)
        }
    }
    private func writeSegmentJSON(segment: DocumentSegment, tags: GeneratedTags, outputDirectory: URL) {
        guard let firstFile = segment.pdfURLs.first else { return }
        // Write JSON next to the output PDF, using its base name so they match
        let jsonURL: URL
        if let outputPDF = outputURLMap[firstFile] {
            jsonURL = outputPDF.deletingPathExtension().appendingPathExtension("json")
        } else {
            let baseName = firstFile.deletingPathExtension().lastPathComponent
            jsonURL = outputDirectory.appendingPathComponent(baseName + ".json")
        }

        // Build body text with image markers
        var bodyParts: [String] = []
        for (i, url) in segment.pdfURLs.enumerated() {
            let text = i < segment.texts.count ? segment.texts[i] : ""
            bodyParts.append("[Image: \(url.lastPathComponent)]")
            if !text.isEmpty {
                bodyParts.append(text)
            }
        }
        let bodyText = bodyParts.joined(separator: "\n\n")

        // Build JSON dictionary
        var dict: [String: Any] = [:]
        if let date = tags.machineDate {
            dict["date"] = date
        }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }

        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }

        if segment.isBox { dict["format"] = "box_label" }
        if segment.isFolder { dict["format"] = "folder_label" }

        dict["files"] = segment.pdfURLs.map { $0.lastPathComponent }
        dict["body"] = bodyText

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }
    /// Merge multi-page document segments into single PDFs.
    /// Each segment with >1 page gets combined. Single-page segments are left as-is.
    func performDocumentMerging(files: [URL], outputDirectory: URL) {
        // Build segments from current classifications if not already built
        let segs: [DocumentSegment]
        if segments.isEmpty {
            let segmenter = DocumentSegmenter()
            let classifications = jobs.map { $0.result?.classification }
            let texts = jobs.map { $0.result?.text ?? "" }
            segs = segmenter.segment(files: files, classifications: classifications, texts: texts)
        } else {
            segs = segments
        }

        let multiPageSegments = segs.filter { $0.pdfURLs.count > 1 && !$0.isBox && !$0.isFolder }
        guard !multiPageSegments.isEmpty else { return }

        statusMessage = "Merging \(multiPageSegments.count) multi-page documents…"
        let pdfGen = PDFGenerator()

        for (segIdx, segment) in multiPageSegments.enumerated() {
            // Collect the individual output PDFs for this segment
            let sourcePDFs = segment.pdfURLs.compactMap { outputURLMap[$0] }
            guard sourcePDFs.count > 1 else { continue }

            // Name the merged PDF after the first page
            let firstSource = segment.pdfURLs[0]
            let baseName = firstSource.deletingPathExtension().lastPathComponent
            let mergedURL = outputDirectory.appendingPathComponent(baseName + "_merged.pdf")

            do {
                try pdfGen.mergeDocumentPDFs(sourcePDFs: sourcePDFs, outputURL: mergedURL)

                // Apply tags from the first page's individual PDF to the merged PDF
                if let firstJob = jobs.first(where: { $0.sourceURL == firstSource }) {
                    if !firstJob.appliedTags.isEmpty {
                        try? MacOSTagger.applyTags(firstJob.appliedTags, to: mergedURL)
                    }
                }

                // Delete the individual PDFs that were merged
                for pdfURL in sourcePDFs {
                    try? FileManager.default.removeItem(at: pdfURL)
                }

                // Rename the JSON file to match the merged PDF name
                let originalJSONURL = outputDirectory.appendingPathComponent(baseName + ".json")
                let mergedJSONURL = outputDirectory.appendingPathComponent(baseName + "_merged.json")
                if FileManager.default.fileExists(atPath: originalJSONURL.path) {
                    try? FileManager.default.moveItem(at: originalJSONURL, to: mergedJSONURL)
                }

                // Update outputURLMap: point all source URLs in this segment to the merged PDF
                for sourceURL in segment.pdfURLs {
                    outputURLMap[sourceURL] = mergedURL
                }

                statusMessage = "Merged document \(segIdx + 1)/\(multiPageSegments.count): \(baseName) (\(sourcePDFs.count) pages)"
            } catch {
                statusMessage = "Failed to merge \(baseName): \(error.localizedDescription)"
            }
        }
    }
}
