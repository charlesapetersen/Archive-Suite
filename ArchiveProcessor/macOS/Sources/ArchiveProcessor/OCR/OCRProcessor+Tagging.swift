import Foundation
import ArchiveCore
import UserNotifications
import os

extension OCRProcessor {
    /// Resolve every output setting consumed after the main OCR pass. An explicit config wins, then
    /// the retained fresh/resumed-run snapshot; nil preserves the migration fallback until W16.cfg5/6.
    func lateRunOutputSettings(
        for explicitRunConfig: SessionProcessingConfig?
    ) -> (
        pdfImageMB: Double,
        textColumns: Int,
        exportedImageMB: Double,
        stampUnread: Bool,
        taggingMode: TaggingMode,
        mergeDocuments: Bool,
        exportOriginals: Bool
    ) {
        let runConfig = explicitRunConfig ?? activeRunConfig
        let pdf = Self.pdfGenerationSettings(for: runConfig)
        let runTaggingMode = runConfig?.taggingMode ?? taggingMode
        return (
            pdf.imageMB,
            pdf.textColumns,
            runConfig?.exportedImageMB ?? Self.exportedImageMB,
            runTaggingMode.stampsUnread,
            runTaggingMode,
            runConfig?.mergeDocuments ?? mergeDocuments,
            runConfig?.outputImageFile ?? exportOriginals
        )
    }

    // MARK: - W23.m5 — the ONE audited tag-write seam for every Process Files output

    /// Apply Finder tags to ONE output artifact and report whether the write actually landed.
    ///
    /// Every Process Files tag write goes through here. Before W23.m5 each site was its own
    /// `_ = try? MacOSTagger.applyTags(…)`, which swallowed every xattr / coordination / verification /
    /// permission / filesystem failure and then populated `jobs[].appliedTags` **as though the output
    /// were tagged** — so the UI and the model reported tags that are absent on disk, and the Reader
    /// silently omitted the file from tag-driven triage. The bytes were always fine; only the silence
    /// was the bug.
    ///
    /// `nonisolated` because two of the call sites (`exportOriginalImages`, `handleOCRResult`) do their
    /// tag I/O inside a detached task; they return the verdict to the main actor, which records it.
    /// Parameters mirror `MacOSTagger.applyTags` exactly so no site changes its write semantics —
    /// this commit records failures, it does not re-decide what gets written.
    ///
    /// Returns `true` when the write succeeded (including a legitimate no-op — copy-source mode with
    /// no tags to write); `false` only when the primitive threw.
    nonisolated static func writeOutputTags(
        _ tags: [String], to url: URL,
        appColor: String? = nil, colorIsAuthoritative: Bool = false,
        stampUnread: Bool
    ) -> Bool {
        do {
            _ = try MacOSTagger.applyTags(tags, to: url, appColor: appColor,
                                          colorIsAuthoritative: colorIsAuthoritative,
                                          stampUnread: stampUnread)
            return true
        } catch {
            os_log(.error, "Finder-tag write FAILED for %{public}@: %{public}@",
                   url.lastPathComponent, error.localizedDescription)
            return false
        }
    }
    /// `GeneratedTags` overload — the app's own colour is authoritative, so a *subject* tag that is
    /// literally "Red"/"Purple" is never promoted to a Finder label (same guarantee as the primitive).
    nonisolated static func writeOutputTags(
        _ generatedTags: GeneratedTags, to url: URL, stampUnread: Bool
    ) -> Bool {
        writeOutputTags(generatedTags.allTags, to: url,
                        appColor: generatedTags.colorTag, colorIsAuthoritative: true,
                        stampUnread: stampUnread)
    }

    // MARK: - W23.m5-fu — the colour a rewrite re-applies comes from the CLASSIFICATION, not the text

    /// The one Finder colour the app assigns to a page: Red = box label, Purple = folder label,
    /// nil = an ordinary document (label cleared).
    ///
    /// This is the same rule everything else already follows — `TagGenerator` when it builds a fresh
    /// `GeneratedTags`, `applyBoxFolderLabelTags` on a label PDF, `performDocumentMerging` on a merged
    /// PDF, the review flows on a reclassification. The two **read-append-rewrite** sites
    /// (`applyCapturePriorityTags`, `exportOriginalImages`) had no such source: they re-applied an array
    /// of tag NAMES read back off disk, so `MacOSTagger`'s raw-array colour DETECTION ran over it and a
    /// document whose subject tag is literally "Red" was promoted to Finder label 6 — which the Reader
    /// reads as a **box** photo. Deriving the colour here makes a rewrite land exactly the label the
    /// fresh write intended, which is also why the fix is not simply `colorIsAuthoritative: true` with
    /// no colour: that would STRIP the label off every genuine box/folder PDF.
    nonisolated static func authoritativeColor(for classification: DocumentClassification?) -> String? {
        switch classification {
        case .boxLabel: return "Red"
        case .folderLabel: return "Purple"
        default: return nil            // ordinary document, or not classified → no colour
        }
    }
    /// Same rule, reading whichever field carries the job's classification. Every writer keeps the two
    /// in sync (`applyPreGroupedClassifications`, the OCR pass and the review flows all set both), and a
    /// failed re-OCR can blank `result.classification` while the job's own value survives — so coalesce
    /// rather than trust one field, because falling back to "no colour" strips a real label.
    nonisolated static func authoritativeColor(forJob job: OCRJob) -> String? {
        authoritativeColor(for: job.classification ?? job.result?.classification)
    }

    /// Main-actor convenience: write, then record the verdict against the INPUT file that produced this
    /// output. Use this at every main-actor tag site; the detached sites call `writeOutputTags` and hand
    /// the Bool to `recordTagWrite(succeeded:forSource:)` themselves.
    @discardableResult
    func tagOutput(_ tags: [String], at url: URL, source: URL,
                   appColor: String? = nil, colorIsAuthoritative: Bool = false,
                   stampUnread: Bool) -> Bool {
        let ok = Self.writeOutputTags(tags, to: url, appColor: appColor,
                                      colorIsAuthoritative: colorIsAuthoritative,
                                      stampUnread: stampUnread)
        recordTagWrite(succeeded: ok, forSource: source)
        return ok
    }
    @discardableResult
    func tagOutput(_ generatedTags: GeneratedTags, at url: URL, source: URL, stampUnread: Bool) -> Bool {
        tagOutput(generatedTags.allTags, at: url, source: source,
                  appColor: generatedTags.colorTag, colorIsAuthoritative: true,
                  stampUnread: stampUnread)
    }

    /// Record (or clear) one input's tag-write verdict. Self-healing by design: a rotation regen or a
    /// review retry that re-tags that input's output successfully REMOVES its earlier failure, so the
    /// end-of-run warning only ever names work that is still untagged on disk.
    func recordTagWrite(succeeded: Bool, forSource source: URL) {
        untaggedOutputs = Self.updatedOutputWarnings(untaggedOutputs,
                                                     name: source.lastPathComponent, present: !succeeded)
    }
    /// Record (or clear) whether one input's output PDF holds the placeholder image page rather than the
    /// scan (W23.h5-fu). Same self-healing semantics: a regen that embeds the image clears it.
    func recordImagePage(_ outcome: PDFGenerator.ImagePageOutcome, forSource source: URL) {
        placeholderOutputs = Self.updatedOutputWarnings(placeholderOutputs,
                                                        name: source.lastPathComponent,
                                                        present: outcome.isPlaceholder)
    }
    /// Insert-once / remove semantics for the two warning records, order-preserving. Pure + `static`
    /// so the headless driver can prove the self-healing without standing up a processor.
    /// Two inputs with the SAME basename from different folders collapse to one entry — deliberate:
    /// this is an operator warning keyed to a recognizable name, not a per-file ledger, and the name is
    /// still the right thing to go looking for.
    nonisolated static func updatedOutputWarnings(
        _ names: [String], name: String, present: Bool
    ) -> [String] {
        var out = names
        if present {
            if !out.contains(name) { out.append(name) }
        } else {
            out.removeAll { $0 == name }
        }
        return out
    }
    /// Drop every warning recorded against `sources` — used when an output is removed from the run
    /// altogether (review exclusion), so the summary can't name work that no longer exists.
    func forgetOutputWarnings(forSources sources: [URL]) {
        let gone = Set(sources.map { $0.lastPathComponent })
        untaggedOutputs.removeAll { gone.contains($0) }
        placeholderOutputs.removeAll { gone.contains($0) }
    }
    /// Reset both records at the start of a run.
    func clearOutputWarnings() {
        untaggedOutputs = []
        placeholderOutputs = []
    }

    /// The end-of-run warning text for both records, or "" when everything landed cleanly.
    ///
    /// Appended to the "Done. N succeeded, M failed." status line — deliberately NOT only to the batch
    /// log, which is opt-in and defaults to OFF (the same reasoning recorded at the multi-page-routing
    /// warning). Both records hold INPUT file names, which is what the operator recognizes and the only
    /// name that survives `organizeOutput`'s move + renumber. Names up to three; the log lists them all.
    nonisolated static func outputWarningSuffix(untagged: [String], placeholders: [String]) -> String {
        var suffix = ""
        if !untagged.isEmpty {
            let n = untagged.count
            suffix += " ⚠️ \(n) file\(n == 1 ? "'s" : "s'") output could NOT be tagged"
                    + " (\(namesForWarning(untagged))) — \(n == 1 ? "it is" : "they are") in the output"
                    + " folder, but \(n == 1 ? "carries" : "carry") NO Finder tags, so tag searches in the"
                    + " Reader will not find \(n == 1 ? "it" : "them"). Re-run \(n == 1 ? "it" : "them"),"
                    + " or check the output folder's permissions."
        }
        if !placeholders.isEmpty {
            let n = placeholders.count
            suffix += " ⚠️ \(n) output PDF\(n == 1 ? "" : "s") could NOT embed the original image"
                    + " (from \(namesForWarning(placeholders))) — \(n == 1 ? "its" : "their") image page is"
                    + " a placeholder, not the scan. The source image\(n == 1 ? " was" : "s were") NOT"
                    + " touched; re-run \(n == 1 ? "it" : "them") to get the image into the archive."
        }
        return suffix
    }
    private nonisolated static func namesForWarning(_ names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        return names.count > 3 ? "\(shown) +\(names.count - 3) more" : shown
    }

    /// Applies Red/Purple color tags to box/folder label PDFs when full LLM tagging
    /// is disabled (or when passing source tags through). When automatic tagging is enabled
    /// these tags are already applied by the normal tagging pass, so this is a no-op.
    func applyBoxFolderLabelTags(
        enableTagging: Bool,
        runConfig: SessionProcessingConfig? = nil
    ) {
        guard !enableTagging || passSourceTags else { return }
        applyBoxFolderLabelTagsUnconditionally(runConfig: runConfig)
    }
    /// Applies Red/Purple color tags to every box/folder label output PDF, unconditionally.
    /// Used by manual tagging modes, which don't run the automatic tagging pass.
    private func applyBoxFolderLabelTagsUnconditionally(
        runConfig: SessionProcessingConfig? = nil
    ) {
        let stampUnread = lateRunOutputSettings(for: runConfig).stampUnread
        for job in jobs {
            guard let classification = job.result?.classification else { continue }
            let tags: GeneratedTags
            switch classification {
            case .boxLabel: tags = GeneratedTags(subjectTags: ["Box"], colorTag: "Red")
            case .folderLabel: tags = GeneratedTags(subjectTags: ["Folder"], colorTag: "Purple")
            default: continue
            }
            if let outputPDF = outputURLMap[job.sourceURL] {
                // Mode-dependent: reached BOTH from `applyBoxFolderLabelTags` (only when tagging is
                // off or copy-source → verbatim) AND unconditionally from the manual tagging modes
                // (→ real-tagging, label written + trailing Unread). Must follow the run's mode.
                tagOutput(tags, at: outputPDF, source: job.sourceURL, stampUnread: stampUnread)
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
        guard index >= 0, index < preGroupedMonths.count, let m = preGroupedMonths[index] else { return nil }
        return GeneratedTags.monthTag(m)
    }
    /// Live Capture: layer each page's phone-set priority ("P10"…"P7") onto whatever the tagging
    /// phase applied. macOS tag application replaces, so read → append → re-apply; also record it in
    /// the job's appliedTags so document merging carries it. No-op outside a pre-grouped run.
    func applyCapturePriorityTags(runConfig: SessionProcessingConfig? = nil) {
        guard !preGroupedPriorities.isEmpty else { return }
        let stampUnread = lateRunOutputSettings(for: runConfig).stampUnread
        for i in jobs.indices where i < preGroupedPriorities.count {
            guard let raw = preGroupedPriorities[i]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty,
                  let outputPDF = outputURLMap[jobs[i].sourceURL] else { continue }
            guard var tags = try? MacOSTagger.readTags(from: outputPDF) else { continue }
            if !tags.contains(raw) {
                tags.append(raw)
                // Read-append-rewrite of whatever the tagging phase already applied — follow the
                // run's mode so a real-tagging output keeps "Unread" last and its label intact.
                // W23.m5-fu: the tags are an array read back off DISK, so the colour must come from
                // the page's classification (as the fresh write's did) — never from detection over
                // those names, which promoted a subject tag "Red" to the box label.
                tagOutput(tags, at: outputPDF, source: jobs[i].sourceURL,
                          appColor: Self.authoritativeColor(forJob: jobs[i]),
                          colorIsAuthoritative: true, stampUnread: stampUnread)
            }
            if !jobs[i].appliedTags.contains(raw) { jobs[i].appliedTags.append(raw) }
        }
    }

    /// Exclude one item from review and remove only output that the Processor itself generated.
    /// Pre-OCRed inputs deliberately map `outputURLMap[source] = source`; detach that mapping without
    /// deleting the user's original PDF or a same-basename source sidecar.
    @discardableResult
    func discardGeneratedOutput(for sourceURL: URL) -> Bool {
        guard let outputURL = outputURLMap[sourceURL] else { return true }
        if OutputFileSafety.isSameFile(outputURL, sourceURL) {
            outputURLMap[sourceURL] = nil
            return true
        }
        do {
            try OutputFileSafety.removeGeneratedOutput(outputURL, for: sourceURL)
            outputURLMap[sourceURL] = nil
            // W23.m5 — the output is gone; drop any warning that would name it at the end of the run.
            forgetOutputWarnings(forSources: [sourceURL])
            return true
        } catch {
            statusMessage = "Could not remove generated output for \(sourceURL.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }
    /// Live Capture dual output: write each page's original image next to its PDF (same base name),
    /// tagged identically, so the final folder holds BOTH the image and the PDF. Runs before merge/
    /// organization so `outputURLMap` is still per-page; `organizeOutput` moves the sibling image too.
    func exportOriginalImages(runConfig: SessionProcessingConfig? = nil) async {
        let outputSettings = lateRunOutputSettings(for: runConfig)
        guard outputSettings.exportOriginals else { return }
        let exportedMB = outputSettings.exportedImageMB
        // Snapshot the work on the main actor… The exported image is always a .jpg sized toward the
        // exported-image target (independent of the source/camera size).
        var imageMap: [URL: URL] = [:]
        var reservedImagePaths = Set<String>()
        let work: [(src: URL, img: URL, pdf: URL, rot: Int, source: URL, color: String?)] = jobs.compactMap { job in
            guard let pdfURL = outputURLMap[job.sourceURL],
                  FileManager.default.fileExists(atPath: job.sourceURL.path) else { return nil }
            // For PDF inputs, export from the converted temp JPEG (the same page image the PDF embeds),
            // not the raw .pdf — matching every PDFGenerator call site.
            let src = pdfToImageMap[job.sourceURL] ?? job.sourceURL
            // The exported image's name matches the PER-PAGE PDF (base + .jpg) at this point — i.e. BEFORE
            // merge repoints outputURLMap to a single merged PDF. Record it keyed by the original source so
            // organizeOutput can file a merged doc's per-page images into the collection folder.
            let preferred = pdfURL.deletingPathExtension().appendingPathExtension("jpg")
            let img = OutputFileSafety.reserveUniqueDestination(
                preferred: preferred,
                allowedExisting: src,
                reservedPaths: &reservedImagePaths
            )
            imageMap[job.sourceURL] = img
            // Snapshot the final (post-review) rotation so the exported .jpg matches the rotated PDF.
            // W23.m5-fu: snapshot the classification's colour too — the detached worker mirrors tag
            // NAMES read off the PDF, and only the job knows which colour those names came with.
            return (src: src, img: img, pdf: pdfURL, rot: job.result?.rotationDegrees ?? 0,
                    source: job.sourceURL, color: Self.authoritativeColor(forJob: job))
        }
        guard !work.isEmpty else { return }
        exportedImageMap = imageMap
        // Capture the run's stamping mode on the MainActor — the detached task below must not touch
        // the @MainActor `taggingMode` (same pattern as `exportedMB` above).
        let isStamping = outputSettings.stampUnread
        // …then encode the sized JPEGs + mirror the PDF's tags OFF the main thread, so the UI never
        // stalls on large files. writeSizedJPEG copies already-small unrotated JPEGs byte-for-byte.
        // W23.m5 — the detached worker can't touch the main-actor record, so it returns one verdict per
        // exported image and the main actor files them below.
        let verdicts: [(source: URL, ok: Bool)] = await Task.detached(priority: .utility) {
            var verdicts: [(source: URL, ok: Bool)] = []
            for w in work {
                // Never write onto the source itself: when the output dir == the input dir and the source
                // is a same-base .jpg, the exported-image path equals the original photo, and writeSizedJPEG
                // would delete/overwrite the irreplaceable original. Skip — the pristine original stays in
                // place as the image half of the dual output, and organizeOutput's moveSiblingImages step
                // relocates it non-destructively. Prove filesystem identity rather than comparing path text:
                // case-sensitive volumes may hold distinct `Photo.JPG` and `photo.jpg` files.
                if OutputFileSafety.isSameFile(w.img, w.src) { continue }
                guard ImageEncoding.writeSizedJPEG(from: w.src, to: w.img, targetMB: exportedMB, rotationDegrees: w.rot) else { continue }
                // Mirror the PDF's tags onto the image (applyTags re-stamps the trailing "Unread"
                // in real-tagging modes, so the image always matches the PDF, ending with "Unread").
                // An unreadable PDF is itself an untagged-image outcome — record it rather than
                // skipping silently, which is what left this half of the dual output invisible.
                guard let tags = try? MacOSTagger.readTags(from: w.pdf) else {
                    verdicts.append((w.source, false))
                    continue
                }
                // W23.m5-fu: the tag NAMES mirror the PDF, but the COLOUR comes from the page's
                // classification — the same one the PDF's own label was written from. Detecting
                // "Red"/"Purple" inside the names would stamp the box label onto the image of any
                // document whose subject happens to be that word.
                verdicts.append((w.source, Self.writeOutputTags(tags, to: w.img, appColor: w.color,
                                                                colorIsAuthoritative: true,
                                                                stampUnread: isStamping)))
            }
            return verdicts
        }.value
        for v in verdicts { recordTagWrite(succeeded: v.ok, forSource: v.source) }
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
        files: [URL],
        runConfig: SessionProcessingConfig? = nil
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
                enableSegmentJSON: enableSegmentJSON,
                runConfig: runConfig
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
        enableSegmentJSON: Bool,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        // Apply Red/Purple color tags to box/folder segments (they aren't manually tagged).
        applyBoxFolderLabelTagsUnconditionally(runConfig: runConfig)
        let stampUnread = lateRunOutputSettings(for: runConfig).stampUnread

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
            tags.month = Self.normalizeMonth(m.month)
            tags.day = Self.normalizeDay(m.day)
            tags.dateUncertain = m.dateUncertain
            tags.subjectTags = m.subjectTags

            for sourceURL in seg.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    // Manual tagging modes are real-tagging modes; follow the run's mode.
                    tagOutput(tags, at: outputPDF, source: sourceURL, stampUnread: stampUnread)
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
        let localAgent = currentLocalAgent
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
                        apiKey: apiKey, gatewayConfig: gateway, localAgent: localAgent
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
                            apiKey: apiKey, gatewayConfig: gateway, localAgent: localAgent
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
        files: [URL],
        runConfig: SessionProcessingConfig? = nil
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
            if discardGeneratedOutput(for: sourceURL) {
                removedSourceURLs.insert(sourceURL)
                jobs[fileIndex].status = .removed
            }
        }

        // (b) Rotation: bake any corrected rotation into the output PDF by regenerating it. Skipped
        // for pre-OCRed input, where the "output" IS the user's original source PDF (regen would
        // overwrite it). Must run before merge (which deletes per-page PDFs) and before tag apply
        // (regen overwrites the PDF, which would clobber freshly-applied Finder tags).
        let outputSettings = lateRunOutputSettings(for: runConfig)
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
                    do {
                        // W23.h5-fu — the regen re-decides whether the scan embedded; record the fresh
                        // verdict so a rotation fix clears (or raises) the placeholder warning.
                        let imagePage = try PDFGenerator().generate(
                            imageURL: imageURL, result: updated, model: model, outputURL: outputURL,
                            originalFileName: jobs[fileIndex].sourceURL.lastPathComponent,
                            gatewayDisplayName: currentGateway?.displayName,
                            pdfImageMB: outputSettings.pdfImageMB,
                            textColumns: outputSettings.textColumns
                        )
                        recordImagePage(imagePage, forSource: jobs[fileIndex].sourceURL)
                    } catch {
                        os_log(.error, "Manual-seg rotation PDF regen failed for %{public}@: %{public}@",
                               jobs[fileIndex].sourceURL.lastPathComponent, error.localizedDescription)
                    }
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
        applyBoxFolderLabelTagsUnconditionally(runConfig: runConfig)

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
            gtags.month = Self.normalizeMonth(data.month)
            gtags.day = Self.normalizeDay(data.day)
            gtags.dateUncertain = data.dateUncertain
            gtags.subjectTags = data.subjectTags

            for sourceURL in seg.pdfURLs {
                if let outputPDF = outputURLMap[sourceURL] {
                    // Manual segment tagging is a real-tagging mode; follow the run's mode.
                    tagOutput(gtags, at: outputPDF, source: sourceURL, stampUnread: outputSettings.stampUnread)
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
        // Once the last document segment is tagged, finish automatically — no explicit Finish click.
        if manualSegRemainingDocCount == 0 {
            confirmManualSegTag()
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
        enableSegmentJSON: Bool = true,
        runConfig: SessionProcessingConfig? = nil
    ) async {
        let generator = TagGenerator()
        let snapshot = segments
        let total = snapshot.count
        guard total > 0 else { return }
        // Capture immutable inputs for the concurrent tasks.
        let vocabulary = tagVocabulary
        let gateway = currentGateway
        let localAgent = currentLocalAgent
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
                        apiKey: apiKey, vocabulary: vocabulary, gatewayConfig: gateway, localAgent: localAgent
                    )
                    return (i, tags)
                }
                next += 1
            }
            for await (i, rawTags) in group {
                if Task.isCancelled { break }
                applyGeneratedTags(rawTags, toSegmentAt: i, in: snapshot,
                                   enableSegmentJSON: enableSegmentJSON, outputDirectory: outputDirectory,
                                   runConfig: runConfig)
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
                            apiKey: apiKey, vocabulary: vocabulary, gatewayConfig: gateway, localAgent: localAgent
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
                                    enableSegmentJSON: Bool, outputDirectory: URL,
                                    runConfig: SessionProcessingConfig?) {
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
                tagOutput(tags, at: outputPDF, source: sourceURL,
                          stampUnread: lateRunOutputSettings(for: runConfig).stampUnread)
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

        // Body + fields come from the shared SegmentJSONBuilder; this path adds the box/folder label
        // format override. The sidecar-URL computation above and the atomic write below are unchanged.
        let formatOverride = SegmentJSONBuilder.labelFormatOverride(isBox: segment.isBox, isFolder: segment.isFolder)
        guard let data = SegmentJSONBuilder.buildData(fileURLs: segment.pdfURLs, texts: segment.texts,
                                                      tags: tags, formatOverride: formatOverride) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }
    /// Merge multi-page document segments into single PDFs.
    /// Each segment with >1 page gets combined. Single-page segments are left as-is.
    typealias MergedTagWriter = (_ tags: [String], _ url: URL,
                                 _ appColor: String?, _ colorIsAuthoritative: Bool) throws -> Void

    func performDocumentMerging(
        files: [URL],
        outputDirectory: URL,
        runConfig: SessionProcessingConfig? = nil,
        tagWriter: MergedTagWriter? = nil
    ) {
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
        let stampUnread = lateRunOutputSettings(for: runConfig).stampUnread

        for (segIdx, segment) in multiPageSegments.enumerated() {
            // Collect the individual output PDFs for this segment
            let sourcePDFs = segment.pdfURLs.compactMap { outputURLMap[$0] }
            guard sourcePDFs.count > 1 else { continue }

            // Name the merged PDF after the first page's OUTPUT (dedup'd) name, not the raw
            // source — two segments sharing a source basename would otherwise overwrite each other.
            let firstOutputPDF = sourcePDFs[0]
            let baseName = firstOutputPDF.deletingPathExtension().lastPathComponent
            let originalJSONURL = firstOutputPDF.deletingPathExtension().appendingPathExtension("json")
            let hasJSON = FileManager.default.fileExists(atPath: originalJSONURL.path)

            // Reserve the merged PDF and its optional JSON sidecar as one basename. A JSON-only prior-run
            // collision must advance the PDF too, or downstream organization cannot keep the pair aligned.
            var mergedBaseName = baseName + "_merged"
            var mergedURL = outputDirectory.appendingPathComponent(mergedBaseName + ".pdf")
            var mergedJSONURL = outputDirectory.appendingPathComponent(mergedBaseName + ".json")
            var mergeN = 2
            while _takenOutputPaths.contains(OutputFileSafety.pathKey(mergedURL))
                  || FileManager.default.fileExists(atPath: mergedURL.path)
                  || (hasJSON && FileManager.default.fileExists(atPath: mergedJSONURL.path)) {
                mergedBaseName = "\(baseName)_merged (\(mergeN))"
                mergedURL = outputDirectory.appendingPathComponent(mergedBaseName + ".pdf")
                mergedJSONURL = outputDirectory.appendingPathComponent(mergedBaseName + ".json")
                mergeN += 1
            }
            _takenOutputPaths.insert(OutputFileSafety.pathKey(mergedURL))

            do {
                try pdfGen.mergeDocumentPDFs(sourcePDFs: sourcePDFs, outputURL: mergedURL)

                // Apply tags to the merged PDF. Prefer the first page's tags, but fall back to the
                // first page in the segment that actually has tags, so the merged PDF isn't left
                // untagged when only a later page carried tags.
                let segmentJobs = segment.pdfURLs.compactMap { src in jobs.first(where: { $0.sourceURL == src }) }
                // Empty generated tags still mean `Unread` in real-tagging modes. Select a segment job
                // even when its explicit array is empty whenever the adapter is stamping that implicit tag.
                let tagged = segmentJobs.first(where: { !$0.appliedTags.isEmpty })
                    ?? (stampUnread ? segmentJobs.first : nil)
                if let tagged {
                    // Derive the authoritative color from the classification so a subject
                    // tag "Red"/"Purple" isn't promoted to a Finder color label.
                    let color: String? = tagged.classification == .boxLabel ? "Red" :
                                         tagged.classification == .folderLabel ? "Purple" : nil
                    if let tagWriter {
                        try tagWriter(tagged.appliedTags, mergedURL, color, true)
                    } else {
                        _ = try MacOSTagger.applyTags(tagged.appliedTags, to: mergedURL,
                                                     appColor: color, colorIsAuthoritative: true,
                                                     stampUnread: stampUnread)
                    }
                }

                // Relocate the sidecar before any component PDF is retired or mapping is advanced. The
                // transaction copy-verifies and removes the source only after the destination is durable;
                // any error falls into the recovery path with every component and mapping still intact.
                if hasJSON {
                    try OutputFileSafety.relocateArtifactSet([
                        .init(source: originalJSONURL, destination: mergedJSONURL)
                    ])
                }

                // Retire component PDFs ONLY after tag transfer returned successfully. A read/write/
                // verification failure leaves both the components and merged recovery copy in place,
                // and the unchanged outputURLMap keeps the run retryable instead of silently losing tags.
                for pdfURL in sourcePDFs {
                    try? FileManager.default.removeItem(at: pdfURL)
                }

                // W23.m5 — every page of this segment is now covered by ONE merged PDF, and the tag
                // write for it is the `try` above (reaching here means it landed). So each page's earlier
                // tag failure is resolved and must be cleared, or the summary would keep naming work that
                // is now correctly tagged. Gated on a write having actually HAPPENED: in a no-tagging run
                // `tagged` is nil and nothing was written, so there is no verdict to record. The
                // PLACEHOLDER record is deliberately NOT cleared either way — those pages are copied into
                // the merged PDF exactly as they were, and the page still to be re-run is identified by
                // the photo it came from, which is what the record already holds.
                if tagged != nil {
                    for pageSource in segment.pdfURLs {
                        recordTagWrite(succeeded: true, forSource: pageSource)
                    }
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
    /// Normalize a free-text month to SPEC "MM Month" format (e.g. "3" → "03 March").
    /// Returns nil for empty/blank input; passes through unrecognized values unchanged.
    private static func normalizeMonth(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let n = GeneratedTags.monthNumber(from: trimmed) {
            return GeneratedTags.monthTag(n)
        }
        return trimmed
    }
    /// Normalize a free-text day to SPEC "Day N" format (e.g. "15" → "Day 15").
    /// Returns nil for empty/blank input; passes through unrecognized values unchanged.
    private static func normalizeDay(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let n = GeneratedTags.dayNumber(from: trimmed) {
            return "Day \(n)"
        }
        return trimmed
    }
}
