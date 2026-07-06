import Foundation
import AppKit

/// Streams processing during Live Capture: OCRs each page **as it arrives**, and finalizes each
/// segment (tagging + PDF + dual-output + optional merge) into a durable staging area as the operator
/// resolves its Mac tag card — overlapping the expensive OCR with capture. End-of-session finalization
/// (Phase 3/4) moves the staged outputs into named collection folders with continuing numbering.
///
/// Reuses the app's tested primitives: `OCRProcessor.performOCRCall` (OCR + rotation), `PDFGenerator`,
/// `TagGenerator`, and `MacOSTagger`. Segmentation is supplied by the phone, so no batch segmentation
/// pass is needed here; a segment's collection is the most-recent preceding **Box** marker.
@MainActor
final class LiveCaptureProcessor: ObservableObject {

    /// Live per-segment status for the UI.
    struct SegmentStatus: Identifiable {
        let id: String                 // groupId
        var index: Int
        var type: CaptureGroupType
        var pageCount: Int
        var phase: Phase
        enum Phase: String { case ocr = "OCR…", tagging = "Tagging…", staged = "Staged", failed = "Failed" }
    }

    /// A staged, fully-processed segment awaiting end-of-session finalization (this is the manifest).
    struct StagedSegment: Codable {
        let groupId: String
        let type: String               // CaptureGroupType.rawValue
        var collectionKey: String      // most-recent Box groupId, or "__unfiled__"
        var order: Int
        var pdfURLs: [URL]
        var imageURLs: [URL]
        var jsonURL: URL?
        var boxLabelText: String?
    }

    @Published private(set) var statuses: [SegmentStatus] = []
    @Published private(set) var staged: [StagedSegment] = []

    /// End-of-session rotation review (opt-in) — a dedicated pass over every captured page, shown at
    /// Finish before collection naming. One editable row per staged page.
    struct RotationReviewPage: Identifiable {
        let id = UUID()
        let groupId: String
        let pageIndex: Int        // index within its segment's pages
        let order: Int            // segment capture order (for stable sorting)
        let sourceURL: URL
        var rotationDegrees: Int
    }
    @Published var showRotationReview = false
    @Published var rotationReviewPages: [RotationReviewPage] = []

    /// End-of-session finalization state (Phase 3/4).
    @Published var drafts: [CollectionDraft] = []
    @Published var showFinalizeSheet = false
    @Published private(set) var isFinalizing = false
    @Published private(set) var finalizeSummary: String?
    /// Document segments whose OCR produced no text (filed as image-only PDFs; retryable).
    @Published private(set) var failedGroupIds: Set<String> = []

    private unowned let session: CaptureSession
    private var config: SessionProcessingConfig?
    private var stagingDir: URL?

    private var pageTasks: [UUID: Task<OCRResult, Never>] = [:]
    private var startedPhotoIds: Set<UUID> = []
    private var finalizedGroups: Set<String> = []
    /// Everything `writeSegmentFiles` needs, retained per finalized segment so the end-of-session
    /// rotation review can regenerate a segment's staged PDF/JPG with corrected rotation. In-memory
    /// for the current run only (rotation review is a same-session step, before finalization).
    private var retained: [String: RetainedSegment] = [:]
    private var currentCollectionKey = "__unfiled__"
    /// Each group's collection, pinned when its first photo arrives (in capture order) so it's
    /// independent of the order segments happen to finalize in.
    private var groupCollectionKey: [String: String] = [:]

    private static let englishMonthNames = ["January", "February", "March", "April", "May", "June",
                                            "July", "August", "September", "October", "November", "December"]

    init(session: CaptureSession) { self.session = session }

    // MARK: - Lifecycle

    /// Arm the coordinator for a `.live` session. Called from `CaptureSession.chooseLive`.
    func activate(config: SessionProcessingConfig) {
        self.config = config
        let dir = config.outputDirectory
            .appendingPathComponent(".ArchiveProcessor-LiveStaging", isDirectory: true)
            .appendingPathComponent(session.sessionId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDir = dir
        // Arm the shared tagging knobs for this session's writes.
        MacOSTagger.stampUnread = config.taggingMode.stampsUnread
        OCRProcessor.rotationModeForRun = config.rotationMode
        OCRProcessor.loadStandardImageMB()

        loadStagingManifest()   // resume: reload already-staged segments so they're not re-OCR'd
        // Process photos already received (resume after a crash, or "chose live after some capture").
        for photo in session.photos { photoIngested(photo) }
        for group in session.groups where group.type == .document
            && session.resolvedGroupIds.contains(group.id) && !finalizedGroups.contains(group.id) {
            let gid = group.id
            Task { [weak self] in await self?.finalizeSegment(groupId: gid) }
        }
    }

    /// Resume: reload segments already staged before a crash/relaunch so they aren't re-processed.
    private func loadStagingManifest() {
        guard let stagingDir else { return }
        let url = stagingDir.appendingPathComponent("staging-manifest.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        var restored: [StagedSegment] = []
        if let manifest = try? decoder.decode(StagingManifest.self, from: data) {
            restored = manifest.staged
            for r in manifest.retained { retained[r.groupId] = r }   // enables the rotation review after resume
        } else if let legacy = try? decoder.decode([StagedSegment].self, from: data) {
            restored = legacy   // legacy manifest (pre-rotation-review): no retained inputs
        }
        guard !restored.isEmpty else { return }
        staged = restored
        for s in restored {
            finalizedGroups.insert(s.groupId)
            groupCollectionKey[s.groupId] = s.collectionKey
            if !statuses.contains(where: { $0.id == s.groupId }) {
                statuses.append(SegmentStatus(id: s.groupId, index: statuses.count + 1,
                    type: CaptureGroupType(rawValue: s.type) ?? .document,
                    pageCount: max(s.imageURLs.count, s.pdfURLs.count), phase: .staged))
            }
        }
        // Restore the "current collection" so subsequent captures file under the right Box.
        if let lastBox = restored.filter({ $0.type == CaptureGroupType.box.rawValue }).max(by: { $0.order < $1.order }) {
            currentCollectionKey = lastBox.groupId
        }
    }

    /// Re-run OCR for segments that produced no text, then re-finalize them.
    func retryFailed() {
        guard session.processingMode == .live else { return }
        let fm = FileManager.default
        var toReprocess: [String] = []
        for gid in Array(failedGroupIds) {
            guard let group = session.groups.first(where: { $0.id == gid }) else { failedGroupIds.remove(gid); continue }
            // Delete the old (failed) staged output + retained state first, so we don't orphan files
            // on disk or re-review stale rotation for a segment we're about to regenerate.
            if let old = staged.first(where: { $0.groupId == gid }) {
                for u in old.pdfURLs { try? fm.removeItem(at: u) }
                for u in old.imageURLs { try? fm.removeItem(at: u) }
                if let j = old.jsonURL { try? fm.removeItem(at: j) }
            }
            finalizedGroups.remove(gid)
            failedGroupIds.remove(gid)
            staged.removeAll { $0.groupId == gid }
            retained[gid] = nil
            for p in group.photos { startedPhotoIds.remove(p.id); pageTasks[p.id] = nil }
            setPhase(gid, .ocr)
            toReprocess.append(gid)
        }
        // Persist the cleaned state BEFORE re-processing, so a crash mid-retry leaves a consistent
        // manifest (failed segments removed) rather than a half-updated one.
        persistManifest()
        for gid in toReprocess {
            guard let group = session.groups.first(where: { $0.id == gid }) else { continue }
            for p in group.photos { photoIngested(p) }
            if group.type == .document { segmentResolved(groupId: gid) }
        }
    }

    /// Whether a group has been finalized (staged) this session — the Mac uses this to avoid removing
    /// a reclassified photo's source out from under an already-staged live segment.
    func isFinalized(_ groupId: String) -> Bool { finalizedGroups.contains(groupId) }

    // MARK: - Triggers (called by CaptureSession)

    /// A photo landed. Start its OCR immediately (max overlap). Box/Folder markers (single image,
    /// no tag card) also finalize right away.
    func photoIngested(_ photo: CapturedPhoto) {
        guard session.processingMode == .live, let config,
              !startedPhotoIds.contains(photo.id),
              !finalizedGroups.contains(photo.groupId) else { return }   // skip already-staged (resume)
        startedPhotoIds.insert(photo.id)

        // Pin collection membership now, in capture order (a Box starts a new collection).
        if photo.type == .box { currentCollectionKey = photo.groupId }
        if groupCollectionKey[photo.groupId] == nil {
            groupCollectionKey[photo.groupId] = (photo.type == .box) ? photo.groupId : currentCollectionKey
        }

        pageTasks[photo.id] = Self.ocrTask(
            imageURL: photo.url, provider: config.provider, model: config.model,
            thinkingLevel: config.thinkingLevel, apiKey: config.apiKey,
            customPrompt: config.customOCRPrompt.isEmpty ? nil : config.customOCRPrompt,
            imageScale: config.imageScale, gateway: config.gateway)

        let pageCount = session.groups.first(where: { $0.id == photo.groupId })?.photos.count ?? 1
        upsertStatus(groupId: photo.groupId, type: photo.type, pageCount: pageCount,
                     phase: photo.type == .document ? .ocr : .tagging)

        if photo.type != .document {   // Box/Folder marker → finalize now
            Task { [weak self] in await self?.finalizeSegment(groupId: photo.groupId) }
        }
    }

    /// A document segment's Mac tag card was resolved (Save/Skip) → finalize it.
    func segmentResolved(groupId: String) {
        guard session.processingMode == .live else { return }
        Task { [weak self] in await self?.finalizeSegment(groupId: groupId) }
    }

    // MARK: - Finalize one segment

    private func finalizeSegment(groupId: String) async {
        guard session.processingMode == .live, let config, let stagingDir,
              !finalizedGroups.contains(groupId),
              let group = session.groups.first(where: { $0.id == groupId }) else { return }
        finalizedGroups.insert(groupId)
        session.lockSettings()   // first finalize locks the session's settings

        let collectionKey = groupCollectionKey[groupId] ?? (group.type == .box ? group.id : currentCollectionKey)
        setPhase(groupId, .tagging)

        // Await the OCR results for this segment's pages (started on arrival).
        var results: [OCRResult] = []
        var texts: [String] = []
        for photo in group.photos {
            let r = await pageTasks[photo.id]?.value
                ?? OCRResult(text: nil, classification: nil, errorMessage: "OCR not started", errorCode: nil)
            results.append(r)
            texts.append(r.text ?? "")
        }

        // Tags: Mac subjects skip the LLM; automatic mode calls the LLM; box/folder → color tag.
        let mac = session.macTags[groupId]
        let segment = DocumentSegment(pdfURLs: group.photos.map { $0.url },
                                      isBox: group.type == .box, isFolder: group.type == .folder, texts: texts)
        var tags = await computeTags(group: group, segment: segment, mac: mac, config: config)
        // Phone's in-the-room date wins (Mac override beats the phone value).
        if let y = mac?.year ?? group.year { tags.year = String(y); tags.dateUncertain = false }
        if let m = mac?.month ?? group.month, (1...12).contains(m) {
            tags.month = String(format: "%02d %@", m, Self.englishMonthNames[m - 1])
        }

        // Snapshot Sendable per-page work for the off-main file writes.
        let pages: [PageWork] = group.photos.enumerated().map { (i, p) in
            let pr = (p.priority == "P10") ? "P10" : (mac?.priority ?? p.priority)
            return PageWork(sourceURL: p.url, result: results[i], priority: pr)
        }
        let gType = group.type, gOrder = group.order
        let baseTags = tags.allTags
        let doMerge = config.mergeDocuments && gType == .document && pages.count > 1
        let model = config.model, gatewayName = config.gateway?.displayName
        let writeJSON = config.enableSegmentJSON && gType == .document
        let jsonTags = tags
        let outputImageFile = config.outputImageFile, pdfImageMB = config.pdfImageMB, exportedImageMB = config.exportedImageMB

        let outcome = await Task.detached(priority: .userInitiated) { () -> StagedSegment in
            Self.writeSegmentFiles(groupId: groupId, type: gType, collectionKey: collectionKey, order: gOrder,
                                   pages: pages, baseTags: baseTags, doMerge: doMerge, model: model,
                                   gatewayName: gatewayName, stagingDir: stagingDir, writeJSON: writeJSON,
                                   jsonTags: jsonTags, texts: texts,
                                   boxLabelText: gType == .box ? texts.first : nil,
                                   outputImageFile: outputImageFile, pdfImageMB: pdfImageMB, exportedImageMB: exportedImageMB)
        }.value

        staged.append(outcome)
        // Retain the write inputs so an end-of-session rotation review can regenerate this segment.
        retained[groupId] = RetainedSegment(
            groupId: groupId, type: gType, collectionKey: collectionKey, order: gOrder,
            pages: pages, baseTags: baseTags, doMerge: doMerge, model: model, gatewayName: gatewayName,
            writeJSON: writeJSON, jsonTags: jsonTags, texts: texts,
            boxLabelText: gType == .box ? texts.first : nil,
            outputImageFile: outputImageFile, pdfImageMB: pdfImageMB, exportedImageMB: exportedImageMB)
        persistManifest()
        for p in group.photos { pageTasks[p.id] = nil }   // free memory
        let anyText = results.contains { $0.text != nil }
        if gType == .document && !anyText {
            failedGroupIds.insert(groupId); setPhase(groupId, .failed)
        } else {
            failedGroupIds.remove(groupId); setPhase(groupId, .staged)
        }
    }

    /// Compute the segment's subject/color tags (may hit the LLM). Date/priority are layered on later.
    private func computeTags(group: CaptureGroup, segment: DocumentSegment,
                             mac: MacSegmentTags?, config: SessionProcessingConfig) async -> GeneratedTags {
        if group.type != .document {
            // Box/Folder → color tag (TagGenerator returns Box/Red or Folder/Purple with no LLM call).
            return await TagGenerator().generateTags(for: segment, nearbySegments: [], provider: config.provider,
                                                     model: config.model, thinkingLevel: nil, apiKey: config.apiKey,
                                                     vocabulary: [], gatewayConfig: config.gateway)
        }
        if let subs = mac?.subjects, !subs.isEmpty { return GeneratedTags(subjectTags: subs) }   // Mac-tagged → no LLM
        if config.taggingMode == .automatic {
            return await TagGenerator().generateTags(for: segment, nearbySegments: [], provider: config.provider,
                                                     model: config.model, thinkingLevel: nil, apiKey: config.apiKey,
                                                     vocabulary: config.tagVocabulary, gatewayConfig: config.gateway)
        }
        return GeneratedTags()   // manual mode, no Mac subjects → date/priority only
    }

    // MARK: - Off-main file writing (nonisolated static; only touches the filesystem)

    private struct PageWork: Sendable, Codable {
        let sourceURL: URL
        let result: OCRResult
        let priority: String?
    }

    /// All inputs to `writeSegmentFiles` for one finalized segment, retained so the end-of-session
    /// rotation review can regenerate it with corrected page rotation. Persisted in the staging
    /// manifest so the review still works after a crash/relaunch resume.
    private struct RetainedSegment: Sendable, Codable {
        let groupId: String
        let type: CaptureGroupType
        let collectionKey: String
        let order: Int
        var pages: [PageWork]        // var: page rotation is updated before regeneration
        let baseTags: [String]
        let doMerge: Bool
        let model: LLMModel
        let gatewayName: String?
        let writeJSON: Bool
        let jsonTags: GeneratedTags
        let texts: [String]
        let boxLabelText: String?
        let outputImageFile: Bool
        let pdfImageMB: Double
        let exportedImageMB: Double
    }

    nonisolated private static func writeSegmentFiles(
        groupId: String, type: CaptureGroupType, collectionKey: String, order: Int,
        pages: [PageWork], baseTags: [String], doMerge: Bool, model: LLMModel, gatewayName: String?,
        stagingDir: URL, writeJSON: Bool, jsonTags: GeneratedTags, texts: [String], boxLabelText: String?,
        outputImageFile: Bool, pdfImageMB: Double, exportedImageMB: Double
    ) -> StagedSegment {
        let fm = FileManager.default
        let pdfGen = PDFGenerator()
        var pdfURLs: [URL] = []
        var imageURLs: [URL] = []

        for page in pages {
            let base = page.sourceURL.deletingPathExtension().lastPathComponent
            let stagedPDF = stagingDir.appendingPathComponent(base + ".pdf")
            try? pdfGen.generate(imageURL: page.sourceURL, result: page.result, model: model,
                                 outputURL: stagedPDF, originalFileName: page.sourceURL.lastPathComponent,
                                 gatewayDisplayName: gatewayName, pdfImageMB: pdfImageMB)
            var tagList = baseTags
            if let pr = page.priority, !tagList.contains(pr) { tagList.append(pr) }
            try? MacOSTagger.applyTags(tagList, to: stagedPDF)
            pdfURLs.append(stagedPDF)

            // Two-file output: a .jpg next to its PDF, sized to the exported-image target + identical tags.
            if outputImageFile {
                let stagedImg = stagingDir.appendingPathComponent(base + ".jpg")
                if ImageEncoding.writeSizedJPEG(from: page.sourceURL, to: stagedImg, targetMB: exportedImageMB, rotationDegrees: page.result.rotationDegrees) {
                    try? MacOSTagger.applyTags(tagList, to: stagedImg)
                    imageURLs.append(stagedImg)
                }
            }
        }

        // Segment JSON (documents only), written from source page names before any merge.
        var jsonURL: URL? = nil
        if writeJSON, type == .document, let firstPDF = pdfURLs.first {
            let jurl = firstPDF.deletingPathExtension().appendingPathExtension("json")
            writeSegmentJSON(pageURLs: pages.map { $0.sourceURL }, texts: texts, tags: jsonTags, to: jurl)
            jsonURL = jurl
        }

        if doMerge, pdfURLs.count > 1 {
            let base = pdfURLs[0].deletingPathExtension().lastPathComponent
            let mergedURL = stagingDir.appendingPathComponent(base + "_merged.pdf")
            do {
                try pdfGen.mergeDocumentPDFs(sourcePDFs: pdfURLs, outputURL: mergedURL)
                var tagList = baseTags
                if let pr = pages.first?.priority, !tagList.contains(pr) { tagList.append(pr) }
                try? MacOSTagger.applyTags(tagList, to: mergedURL)
                for u in pdfURLs { try? fm.removeItem(at: u) }
                pdfURLs = [mergedURL]
            } catch { /* keep the individual PDFs if merge fails */ }
        }

        return StagedSegment(groupId: groupId, type: type.rawValue, collectionKey: collectionKey, order: order,
                             pdfURLs: pdfURLs, imageURLs: imageURLs, jsonURL: jsonURL, boxLabelText: boxLabelText)
    }

    /// Mirrors `OCRProcessor.writeSegmentJSON`: a metadata sidecar with the OCR body + fields.
    nonisolated private static func writeSegmentJSON(pageURLs: [URL], texts: [String], tags: GeneratedTags, to jsonURL: URL) {
        var bodyParts: [String] = []
        for (i, u) in pageURLs.enumerated() {
            let t = i < texts.count ? texts[i] : ""
            bodyParts.append("[Image: \(u.lastPathComponent)]")
            if !t.isEmpty { bodyParts.append(t) }
        }
        var dict: [String: Any] = [:]
        if let d = tags.machineDate { dict["date"] = d }
        dict["date_uncertain"] = tags.dateUncertain
        dict["subjects"] = tags.subjectTags.map { GeneratedTags.capitalizeFirstLetters($0) }
        if let v = tags.format { dict["format"] = v }
        if let v = tags.authorName { dict["author_name"] = v }
        if let v = tags.recipientName { dict["recipient_name"] = v }
        if let v = tags.authorLocation { dict["author_location"] = v }
        if let v = tags.recipientLocation { dict["recipient_location"] = v }
        if let v = tags.publicationName { dict["publication_name"] = v }
        dict["files"] = pageURLs.map { $0.lastPathComponent }
        dict["body"] = bodyParts.joined(separator: "\n\n")
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    nonisolated private static func ocrTask(
        imageURL: URL, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
        apiKey: String, customPrompt: String?, imageScale: Double, gateway: GatewayConfig?
    ) -> Task<OCRResult, Never> {
        Task.detached(priority: .userInitiated) {
            await OCRProcessor.performOCRCall(
                imageURL: imageURL, provider: provider, model: model, thinkingLevel: thinkingLevel,
                apiKey: apiKey, previousText: nil, previousImageURL: nil,
                customPrompt: customPrompt, imageScale: imageScale, gatewayConfig: gateway)
        }
    }

    // MARK: - Manifest + status

    /// On-disk staging manifest: staged segments plus the per-segment write inputs needed to
    /// regenerate a segment during the end-of-session rotation review after a crash/relaunch.
    private struct StagingManifest: Codable {
        var staged: [StagedSegment]
        var retained: [RetainedSegment]
    }

    private func persistManifest() {
        guard let stagingDir else { return }
        let url = stagingDir.appendingPathComponent("staging-manifest.json")
        let manifest = StagingManifest(staged: staged, retained: Array(retained.values))
        if let data = try? JSONEncoder().encode(manifest) { try? data.write(to: url, options: .atomic) }
    }

    private func upsertStatus(groupId: String, type: CaptureGroupType, pageCount: Int, phase: SegmentStatus.Phase) {
        if let idx = statuses.firstIndex(where: { $0.id == groupId }) {
            statuses[idx].pageCount = pageCount
            if statuses[idx].phase != .staged { statuses[idx].phase = phase }
        } else {
            statuses.append(SegmentStatus(id: groupId, index: statuses.count + 1, type: type,
                                          pageCount: pageCount, phase: phase))
        }
    }

    private func setPhase(_ groupId: String, _ phase: SegmentStatus.Phase) {
        if let idx = statuses.firstIndex(where: { $0.id == groupId }) { statuses[idx].phase = phase }
    }

    // MARK: - End-of-session finalization (Phase 3/4)

    /// One collection awaiting the operator's name/append confirmation.
    struct CollectionDraft: Identifiable {
        let id: String                 // collectionKey
        var finalName: String          // editable candidate name
        var existingFolders: [URL]     // all existing collection folders (for the picker)
        var suggestedFolders: [URL]    // fuzzy top matches (shown first)
        var chosenExisting: URL?       // nil → create a new folder; else append to this one
        var segmentCount: Int
        var photoCount: Int
    }

    // MARK: - End-of-session rotation review (opt-in)

    /// Finish-session entry point. If "Review rotation" is on, present a dedicated rotation-review
    /// pass over every captured page first; otherwise go straight to collection naming. "Review
    /// rotation" is read LIVE (not from the locked session config): it's a Finish-time choice, so
    /// enabling it after capture started still applies. Pages seed from each page's detected rotation
    /// (0 if detection was off), and the operator can correct any of them.
    func finishSession() {
        guard !staged.isEmpty else { return }
        let wantReview = UserDefaults.standard.bool(forKey: DefaultsKeys.reviewRotation)
        guard wantReview else { beginFinalize(); return }
        var pages: [RotationReviewPage] = []
        for seg in retained.values {
            for (i, p) in seg.pages.enumerated() {
                pages.append(RotationReviewPage(groupId: seg.groupId, pageIndex: i, order: seg.order,
                                                sourceURL: p.sourceURL,
                                                rotationDegrees: p.result.rotationDegrees))
            }
        }
        pages.sort { ($0.order, $0.pageIndex) < ($1.order, $1.pageIndex) }
        guard !pages.isEmpty else { beginFinalize(); return }
        rotationReviewPages = pages
        showRotationReview = true
    }

    /// Dismiss the rotation review without finalizing (back to capture).
    func cancelRotationReview() {
        showRotationReview = false
        rotationReviewPages = []
    }

    /// Apply the reviewed rotations: regenerate each changed segment's staged PDF/JPG, then proceed
    /// to collection naming. Unchanged pages are left untouched.
    func applyRotationReviewAndFinalize() {
        showRotationReview = false
        var changedGroups: Set<String> = []
        for page in rotationReviewPages {
            guard var seg = retained[page.groupId], page.pageIndex < seg.pages.count else { continue }
            let old = seg.pages[page.pageIndex].result.rotationDegrees
            let new = ((page.rotationDegrees % 360) + 360) % 360
            guard new != old else { continue }
            let pw = seg.pages[page.pageIndex]
            let r = pw.result
            seg.pages[page.pageIndex] = PageWork(
                sourceURL: pw.sourceURL,
                result: OCRResult(text: r.text, classification: r.classification, rotationDegrees: new,
                                  errorMessage: r.errorMessage, errorCode: r.errorCode),
                priority: pw.priority)
            retained[page.groupId] = seg
            changedGroups.insert(page.groupId)
        }
        rotationReviewPages = []
        // Only regenerate segments whose source photos ALL still exist on disk. Regenerating from a
        // missing source (e.g. the operator hit "Clear" before Finish, deleting the originals) would
        // overwrite good staged output with an image-less/broken file — so keep the existing output.
        let fm = FileManager.default
        let segsToRegen = changedGroups
            .compactMap { retained[$0] }
            .filter { seg in seg.pages.allSatisfy { fm.fileExists(atPath: $0.sourceURL.path) } }
        guard !segsToRegen.isEmpty, let stagingDir else { beginFinalize(); return }
        isFinalizing = true
        Task { [weak self] in
            let regenerated: [StagedSegment] = await Task.detached { () -> [StagedSegment] in
                segsToRegen.map { seg in
                    Self.writeSegmentFiles(groupId: seg.groupId, type: seg.type, collectionKey: seg.collectionKey,
                                           order: seg.order, pages: seg.pages, baseTags: seg.baseTags,
                                           doMerge: seg.doMerge, model: seg.model, gatewayName: seg.gatewayName,
                                           stagingDir: stagingDir, writeJSON: seg.writeJSON, jsonTags: seg.jsonTags,
                                           texts: seg.texts, boxLabelText: seg.boxLabelText,
                                           outputImageFile: seg.outputImageFile, pdfImageMB: seg.pdfImageMB,
                                           exportedImageMB: seg.exportedImageMB)
                }
            }.value
            guard let self else { return }
            for outcome in regenerated {
                if let idx = self.staged.firstIndex(where: { $0.groupId == outcome.groupId }) {
                    self.staged[idx] = outcome
                }
            }
            self.persistManifest()
            self.isFinalizing = false
            self.beginFinalize()
        }
    }

    /// Build collection drafts (candidate names + fuzzy-matched existing folders) and show the sheet.
    func beginFinalize() {
        guard let config, !staged.isEmpty else { return }
        let existing = Self.existingCollectionFolders(in: config.outputDirectory)
        let byKey = Dictionary(grouping: staged, by: { $0.collectionKey })
        let orderedKeys = byKey.keys.sorted {
            (byKey[$0]?.map(\.order).min() ?? .max) < (byKey[$1]?.map(\.order).min() ?? .max)
        }
        drafts = orderedKeys.map { key in
            let segs = byKey[key] ?? []
            let candidate = Self.candidateName(segments: segs)
            return CollectionDraft(id: key, finalName: candidate, existingFolders: existing,
                                   suggestedFolders: Self.fuzzyMatches(candidate, in: existing, limit: 3),
                                   chosenExisting: nil, segmentCount: segs.count,
                                   photoCount: segs.reduce(0) { $0 + $1.imageURLs.count })
        }
        showFinalizeSheet = true
    }

    /// Move staged outputs into their (new or existing) collection folders, continuing numbering.
    func finalize(_ decided: [CollectionDraft]) {
        guard let config, let stagingDir, !isFinalizing else { return }
        isFinalizing = true
        let outputDir = config.outputDirectory
        let byKey = Dictionary(grouping: staged, by: { $0.collectionKey })
        let plans: [MovePlan] = decided.map { d in
            let segs = (byKey[d.id] ?? []).sorted { $0.order < $1.order }
            let name = d.chosenExisting?.lastPathComponent ?? Self.sanitize(d.finalName)
            let folder = d.chosenExisting ?? outputDir.appendingPathComponent(name, isDirectory: true)
            return MovePlan(folder: folder, name: name, appending: d.chosenExisting != nil, segments: segs)
        }
        Task { [weak self] in
            let outcome = await Task.detached { Self.executePlans(plans) }.value
            guard let self else { return }
            self.showFinalizeSheet = false
            self.isFinalizing = false
            guard outcome.failedMoves == 0 else {
                // At least one staged output could not be moved into its collection folder. Do NOT delete
                // the staging dir or clear the session — session.clear() deletes the irreplaceable SOURCE
                // photos, so deleting now would lose both the processed output and the original. Keep
                // everything in place so the operator can fix the cause (permissions / free space / a
                // locked destination) and Finish again; already-moved files are skipped on the retry.
                self.finalizeSummary = outcome.summary
                    + " ⚠️ \(outcome.failedMoves) file(s) couldn't be moved — kept in place. Check the output folder and Finish again."
                return
            }
            try? FileManager.default.removeItem(at: stagingDir)   // staging emptied into collections
            // The exact source pages that were actually staged/filed (each retained segment records its
            // pages' source URLs). Compute BEFORE clearing `retained`.
            let filedSources = Set(self.retained.values.flatMap { $0.pages.map { $0.sourceURL } })
            self.staged.removeAll()
            self.statuses.removeAll()
            self.drafts.removeAll()
            self.finalizedGroups.removeAll()
            self.startedPhotoIds.removeAll()
            self.retained.removeAll()
            self.rotationReviewPages.removeAll()
            self.currentCollectionKey = "__unfiled__"
            // Clear ONLY the filed source photos from the Captured pane; KEEP any page that streamed in
            // but was never staged (e.g. a straggler that arrived after its segment finalized) so an
            // irreplaceable photo is never deleted — it stays in the backup folder + pane, recoverable.
            self.session.clearFiled(filedSources)
            self.finalizeSummary = outcome.summary
        }
    }

    /// Clear the "Finalized …" summary (called when new capture begins, or on a manual Clear).
    func clearFinalizeSummary() { if finalizeSummary != nil { finalizeSummary = nil } }

    private struct MovePlan: Sendable {
        let folder: URL; let name: String; let appending: Bool; let segments: [StagedSegment]
    }

    /// Outcome of moving staged files into their collection folders. `failedMoves > 0` means at least one
    /// staged output could NOT be filed — the caller must then keep staging + sources (do not delete either).
    private struct FinalizeOutcome: Sendable { let summary: String; let failedMoves: Int }

    private enum MoveResult { case moved, absent, failed }

    nonisolated private static func executePlans(_ plans: [MovePlan]) -> FinalizeOutcome {
        let fm = FileManager.default
        var movedFiles = 0
        var failedMoves = 0
        func doMove(_ src: URL, to dest: URL) {
            switch move(src, to: dest, fm: fm) {
            case .moved: movedFiles += 1
            case .absent: break                 // nothing staged for this slot (e.g. a page whose gen failed)
            case .failed: failedMoves += 1       // a real move error — the output is still in staging
            }
        }
        for plan in plans {
            try? fm.createDirectory(at: plan.folder, withIntermediateDirectories: true)
            var seq = plan.appending ? maxExistingNumber(in: plan.folder) : 0
            for seg in plan.segments {
                var firstNum: Int?
                if seg.imageURLs.isEmpty {
                    // One-file output (PDF only): number by PDF (a merged doc is already a single PDF).
                    for pdf in seg.pdfURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        doMove(pdf, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).pdf"))
                    }
                } else if seg.pdfURLs.count == 1 && seg.imageURLs.count > 1 {
                    // Merged multi-page document: one PDF for many page images. Number each image, then the
                    // single merged PDF at the first number.
                    for img in seg.imageURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        let ext = img.pathExtension.isEmpty ? "jpg" : img.pathExtension
                        doMove(img, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).\(ext)"))
                    }
                    if let fn = firstNum, let pdf = seg.pdfURLs.first {
                        doMove(pdf, to: plan.folder.appendingPathComponent("\(String(format: "%05d", fn)) \(plan.name).pdf"))
                    }
                } else {
                    // Two-file output, one PDF per page. The PDF list is authoritative (always page-complete);
                    // an exported image can be missing for a page whose JPEG write failed, so do NOT pair by
                    // positional index (that off-by-one mispairs pages and orphans the trailing PDF, which
                    // finalize then deletes). Iterate PDFs and attach the image sharing each PDF's base name.
                    let imgByBase = Dictionary(seg.imageURLs.map { ($0.deletingPathExtension().lastPathComponent, $0) },
                                               uniquingKeysWith: { first, _ in first })
                    for pdf in seg.pdfURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        if let img = imgByBase[pdf.deletingPathExtension().lastPathComponent] {
                            let ext = img.pathExtension.isEmpty ? "jpg" : img.pathExtension
                            doMove(img, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).\(ext)"))
                        }
                        doMove(pdf, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).pdf"))
                    }
                }
                if let json = seg.jsonURL, let fn = firstNum {
                    let jf = plan.folder.appendingPathComponent("JSON Output", isDirectory: true)
                    try? fm.createDirectory(at: jf, withIntermediateDirectories: true)
                    doMove(json, to: jf.appendingPathComponent("\(String(format: "%05d", fn)) \(plan.name).json"))
                }
            }
        }
        let summary = "Finalized \(plans.count) collection\(plans.count == 1 ? "" : "s") · \(movedFiles) files moved."
        return FinalizeOutcome(summary: summary, failedMoves: failedMoves)
    }

    /// Move `src` to `dest`, reporting the outcome so the caller can tell a real failure (output stuck in
    /// staging) apart from a nothing-to-move slot. A missing source is `.absent`, not `.failed`.
    nonisolated private static func move(_ src: URL, to dest: URL, fm: FileManager) -> MoveResult {
        guard fm.fileExists(atPath: src.path) else { return .absent }
        if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
        do { try fm.moveItem(at: src, to: dest); return .moved } catch { return .failed }
    }

    /// Highest leading NNNNN number among files directly in a folder (0 if none) — for append numbering.
    nonisolated private static func maxExistingNumber(in folder: URL) -> Int {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var maxN = 0
        for u in items {
            let prefix = u.lastPathComponent.prefix(5)
            if prefix.count == 5, prefix.allSatisfy(\.isNumber), let n = Int(prefix) { maxN = max(maxN, n) }
        }
        return maxN
    }

    nonisolated private static func existingCollectionFolders(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && !$0.lastPathComponent.hasPrefix(".")
            && $0.lastPathComponent != "JSON Output"
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    nonisolated private static func candidateName(segments: [StagedSegment]) -> String {
        if let box = segments.first(where: { $0.type == CaptureGroupType.box.rawValue }), let label = box.boxLabelText {
            let line = label.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first(where: { !$0.isEmpty }) ?? ""
            return sanitize(String(line.prefix(80)))
        }
        return ""   // no Box marker → operator must name it
    }

    nonisolated private static func sanitize(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        // A dot-only name (".", "..") would resolve via appendingPathComponent to the output dir's parent
        // and write OUTSIDE the intended tree — this name is auto-derived from box-label OCR and
        // auto-accepted in the headless path, so reject it. (Empty also satisfies allSatisfy → fallback.)
        if cleaned.allSatisfy({ $0 == "." }) { cleaned = "" }
        return cleaned.isEmpty ? "Untitled Collection" : cleaned
    }

    /// Fuzzy-rank existing folders against a candidate name (case-insensitive Levenshtein + substring).
    nonisolated private static func fuzzyMatches(_ candidate: String, in folders: [URL], limit: Int) -> [URL] {
        let c = candidate.lowercased().trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, !folders.isEmpty else { return [] }
        return folders.map { (url: $0, score: similarity(c, $0.lastPathComponent.lowercased())) }
            .filter { $0.score >= 0.34 }
            .sorted { $0.score > $1.score }
            .prefix(limit).map { $0.url }
    }

    nonisolated private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a)) { return 0.9 }
        let dist = levenshtein(Array(a), Array(b))
        let maxLen = max(a.count, b.count)
        return maxLen == 0 ? 0 : 1.0 - Double(dist) / Double(maxLen)
    }

    nonisolated private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
