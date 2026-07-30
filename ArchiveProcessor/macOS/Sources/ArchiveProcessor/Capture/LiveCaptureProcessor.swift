import Foundation
import AppKit
import ArchiveCore

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
        /// A1: failure/label detail, populated at finalize. `failureKind` distinguishes the causes the
        /// old single `.failed` collapsed; `errorMessage/errorCode` surface the OCR reason (previously
        /// dropped). These are labeling only — they never affect any finalize/deletion decision.
        var failureKind: FailureKind? = nil
        var errorMessage: String? = nil
        var errorCode: String? = nil
        /// `succeededNoText`: a document that OCR'd to no text but WAS filed as a complete image-only PDF
        /// (amber warning, not a hard failure). It is staged + filed exactly as before — only its label
        /// differs, so bulk "Retry failed" stops over-counting a successfully-filed image-only doc.
        enum Phase: String {
            case ocr = "OCR…", tagging = "Tagging…", staged = "Staged"
            case succeededNoText = "Filed (image-only)"
            case failed = "Failed"
        }
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
        /// Did EVERY source page produce a PDF on disk? `false` ⇒ a page's generation was silently dropped,
        /// so the segment is INCOMPLETE and finalize must NOT file it (deleting its sources would lose the
        /// page that has no output). `nil` ⇒ legacy manifest (older builds never dropped a page) → complete.
        var pagesComplete: Bool?
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
    /// True after the operator hit "Finish session" while segments are still being OCR'd/tagged: we hold
    /// off the rotation review / collection naming until every segment is staged, so none are missed.
    @Published private(set) var pendingFinish = false
    /// Segments still being processed (OCR or tagging), for the "waiting" message shown while pendingFinish.
    var processingCount: Int { statuses.filter { $0.phase == .ocr || $0.phase == .tagging }.count }
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
    /// Bumped by `clearSessionState()`. A `finalizeSegment` that SUSPENDED at an `await` before the operator
    /// hit Clear captures this at its start and re-checks it after each await; if it changed, the session was
    /// cleared out from under it, so finalize bails cleanly — no re-added state, no stale manifest, no orphan
    /// output PDF repopulating the just-cleared Processing pane (B8). A no-op when Clear was never pressed.
    private var clearGeneration = 0
    /// Everything `writeSegmentFiles` needs, retained per finalized segment so the end-of-session
    /// rotation review can regenerate a segment's staged PDF/JPG with corrected rotation. In-memory
    /// for the current run only (rotation review is a same-session step, before finalization).
    private var retained: [String: RetainedSegment] = [:]
    private var currentCollectionKey = "__unfiled__"
    /// Each group's collection, pinned when its first photo arrives (in capture order) so it's
    /// independent of the order segments happen to finalize in.
    private var groupCollectionKey: [String: String] = [:]

    /// Optional per-group OCR override from a per-item "retry with model" / "rotate & re-run". Threaded
    /// into that group's re-OCR (provider/model) and finalize (forced rotation), then cleared once consumed
    /// so a later normal re-finalize doesn't reuse it. Absent for the common (session-config) path.
    struct OCROverride {
        let provider: LLMProvider
        let model: LLMModel
        let thinkingLevel: ThinkingLevel?
        let apiKey: String
        let rotation: Int?
    }
    private var groupOCROverride: [String: OCROverride] = [:]

    init(session: CaptureSession) { self.session = session }

    // MARK: - Lifecycle

    /// Where a session's processed outputs are staged before end-of-session finalize. As of the **Recovery
    /// Core Directive** this lives INSIDE the session's VISIBLE backup folder —
    /// `~/Pictures/Archive Processor Live Capture/<session>/_processed/` — so the staged PDFs/JPGs/JSON
    /// (with tags) sit right next to the raw source photos and are recoverable in Finder if the app fails
    /// before finalize. Co-locating them there also removes a whole class of failure (Application-Support
    /// unavailable, staging pruned out from under the run, session-id mismatch after relaunch) that could
    /// strand or drop already-processed output. Recovery of both sources + processed output is now unified:
    /// one session folder, recovered together.
    static func stagingDir(for session: CaptureSession) -> URL {
        session.incomingFolder.appendingPathComponent("_processed", isDirectory: true)
    }

    /// Legacy flat staging parent used by pre-2026-07 builds (`Application Support/ArchiveProcessor/
    /// LiveStaging/<session>`). Retained ONLY so a session staged by an older build can still resume from
    /// there, and so orphaned leftovers can be cleaned up. New sessions always stage under the visible
    /// backup folder (see `stagingDir(for:)`).
    static var legacyStagingRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? CaptureSession.backupRoot
        return base.appendingPathComponent("ArchiveProcessor/LiveStaging", isDirectory: true)
    }

    /// Best-effort cleanup of orphaned staging dirs left in the LEGACY flat location by older builds. A
    /// legacy staging dir is orphaned when its session's backup folder no longer exists (finalized or
    /// abandoned). NEVER removes one whose backup folder still exists (it may still be resumed from there),
    /// so it cannot discard resumable work. New sessions stage inside the backup folder, where an empty
    /// session folder (its `_processed` included) is pruned by `CaptureSession.pruneEmptySessions`.
    private static func pruneLegacyStaging() {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(at: legacyStagingRoot, includingPropertiesForKeys: nil) else { return }
        for dir in subdirs {
            let backup = CaptureSession.backupRoot.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            if !fm.fileExists(atPath: backup.path) { try? fm.removeItem(at: dir) }
        }
    }

    /// Arm the coordinator for a `.live` session. Called from `CaptureSession.chooseLive`.
    func activate(config: SessionProcessingConfig) {
        self.config = config
        let fm = FileManager.default
        // Primary (Recovery Core Directive): stage inside the session's VISIBLE backup folder, so processed
        // PDFs/JPGs (with tags) are recoverable next to the raw sources if the app fails before finalize.
        let primary = Self.stagingDir(for: session)
        // Back-compat resume: a session staged by an OLDER build lives under the flat Application-Support
        // staging root, and an older-still one under the output folder. If the primary has no manifest yet
        // but a legacy location does, keep using that legacy dir IN PLACE so its already-staged outputs
        // aren't orphaned (or needlessly re-OCR'd). New sessions always use `primary`.
        let legacyAppSupport = Self.legacyStagingRoot.appendingPathComponent(session.sessionId, isDirectory: true)
        let legacyOutput = config.outputDirectory
            .appendingPathComponent(".ArchiveProcessor-LiveStaging", isDirectory: true)
            .appendingPathComponent(session.sessionId, isDirectory: true)
        func hasManifest(_ d: URL) -> Bool { fm.fileExists(atPath: d.appendingPathComponent("staging-manifest.json").path) }
        let dir: URL = hasManifest(primary) ? primary
            : (hasManifest(legacyAppSupport) ? legacyAppSupport
               : (hasManifest(legacyOutput) ? legacyOutput : primary))
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDir = dir
        Self.pruneLegacyStaging()   // best-effort: drop orphaned staging left by older builds
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
        var didMigrateLegacy = false
        if let manifest = try? decoder.decode(StagingManifest.self, from: data) {
            restored = manifest.staged
            for r in manifest.retained { retained[r.groupId] = r }   // enables the rotation review after resume
        } else if let legacy = try? decoder.decode([StagedSegment].self, from: data) {
            // Legacy manifest (bare [StagedSegment], no `retained`): DROP each re-processable segment so the
            // resume path below regenerates it (→ proper `retained` → a COMPLETE rotation review); KEEP any
            // whose sources are gone (can't regenerate). See migrateLegacyManifestSegments (KNOWN_ISSUES #1).
            didMigrateLegacy = true
            let legacyIds = Set(legacy.map(\.groupId))
            let presentGroupIds: Set<String> = Set(
                session.groups
                    .filter { legacyIds.contains($0.id) }
                    .compactMap { g -> String? in
                        let urls = g.photos.map(\.url)
                        return (!urls.isEmpty && urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }) ? g.id : nil
                    })
            let (keep, _) = Self.migrateLegacyManifestSegments(legacy) { presentGroupIds.contains($0) }
            restored = keep
        }
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
        // A migrated legacy manifest is rewritten in the CURRENT format so a crash before any dropped segment
        // re-finalizes doesn't re-enter this branch (idempotent recovery); dropped segments re-process via the
        // normal resume path in `activate()`.
        if didMigrateLegacy { persistManifest() }
    }

    /// Re-run OCR for a set of segments, then re-finalize them. Defaults to the full failed set (the bulk
    /// "Retry failed" / G1 case); pass a single-element set for a per-item retry. `override` (optional)
    /// re-OCRs those segments with a chosen provider/model and/or forces their output rotation instead of
    /// the session's locked config. The body is unchanged from the original bulk retry — it just iterates
    /// the passed set — so the data-safety sequence (delete stale staged output → drop finalized/failed
    /// bookkeeping → persist the cleaned manifest BEFORE re-processing → re-ingest) is identical. A
    /// `.staged`/`.succeededNoText` segment is retryable too: old output is deleted first, so it's safe.
    func retryFailed(groupIds: Set<String>? = nil, override: OCROverride? = nil) {
        guard session.processingMode == .live else { return }
        let targets = groupIds ?? failedGroupIds
        let fm = FileManager.default
        var toReprocess: [String] = []
        for gid in Array(targets) {
            guard let group = session.groups.first(where: { $0.id == gid }) else { failedGroupIds.remove(gid); continue }
            // Delete the old staged output + retained state first, so we don't orphan files
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
            groupOCROverride[gid] = override    // nil clears any prior override
            setStatusDetail(gid, kind: nil, error: nil)   // clear the stale reason line
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

    /// OCR text retained for a segment (joined across its pages), for the shared row's text viewer.
    /// Nil when nothing usable was captured (e.g. an image-only / failed segment).
    func retainedText(for groupId: String) -> String? {
        guard let seg = retained[groupId] else { return nil }
        let joined = seg.texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Staged output files (PDFs + exported images) for a segment, for "Reveal in Finder".
    func stagedURLs(for groupId: String) -> [URL] {
        guard let s = staged.first(where: { $0.groupId == groupId }) else { return [] }
        return s.pdfURLs + s.imageURLs
    }

    // MARK: - Triggers (called by CaptureSession)

    /// A photo landed. Start its OCR immediately (max overlap). Box/Folder markers (single image,
    /// no tag card) also finalize right away.
    func photoIngested(_ photo: CapturedPhoto) {
        guard session.processingMode == .live, let config,
              !startedPhotoIds.contains(photo.id) else { return }   // not live / dup / resume → silent
        if finalizedGroups.contains(photo.groupId) {
            // A page arrived for a document already finalized on the Mac — e.g. the operator kept shooting the
            // SAME document after it was force-completed at Finish, instead of starting a new segment. It can't
            // join that finished collection; it stays in the backup folder. Surface it (don't drop silently).
            session.statusMessage = "A late page arrived for an already-finished document — kept in the Backup Folder, not this collection. Tap Box or End segment to start a NEW segment."
            return
        }
        startedPhotoIds.insert(photo.id)

        // New capture arrived while a Finish is pending: treat it as another segment to include — the
        // pending finish KEEPS waiting and will complete once this segment is tagged + processed too (it's
        // not dropped or force-completed). Just note it. If the operator never ends this new segment, the
        // Finish button stays tappable (see LiveCaptureView) so they can re-issue the recovery.
        if pendingFinish {
            session.statusMessage = "Added to this session — Finish will complete after the new segment is processed too."
        }

        // Pin collection membership now, in capture order (a Box starts a new collection).
        if photo.type == .box {
            currentCollectionKey = photo.groupId
            // Back-fill: on relay transport, docs captured AFTER this box may have arrived first
            // and been pinned to the wrong (previous) collection. Re-assign using capture-seq order.
            backfillCollections()
        }
        if groupCollectionKey[photo.groupId] == nil {
            groupCollectionKey[photo.groupId] = (photo.type == .box) ? photo.groupId : currentCollectionKey
        }

        // A per-item "retry with model" override (if any) re-OCRs this group with the chosen provider/model
        // via a direct API call (no gateway); otherwise use the session's locked config.
        let ov = groupOCROverride[photo.groupId]
        pageTasks[photo.id] = Self.ocrTask(
            imageURL: photo.url,
            provider: ov?.provider ?? config.provider,
            model: ov?.model ?? config.model,
            thinkingLevel: ov.map { $0.thinkingLevel } ?? config.thinkingLevel,
            apiKey: ov?.apiKey ?? config.apiKey,
            customPrompt: config.customOCRPrompt.isEmpty ? nil : config.customOCRPrompt,
            imageScale: config.imageScale, gateway: ov == nil ? config.gateway : nil,
            localAgent: ov == nil ? config.localAgent : nil,
            rotationMode: config.rotationMode, standardImageMB: config.standardImageMB)

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

    /// Re-assign collection keys for not-yet-finalized groups (and already-staged segments) using the
    /// phone's capture sequence as the source of truth. Called when a Box arrives out of relay order so
    /// documents that landed before their Box get corrected before (or after) finalize.
    private func backfillCollections() {
        let boxes = session.groups
            .filter { $0.type == .box }
            .sorted { $0.order < $1.order }
        guard !boxes.isEmpty else { return }

        // For a given capture-order, the correct box is the one with the highest order ≤ docOrder.
        func correctBox(forOrder docOrder: Int) -> CaptureGroup? {
            boxes.last { $0.order <= docOrder }
        }

        // Back-fill not-yet-finalized groups
        for group in session.groups where group.type != .box {
            guard !finalizedGroups.contains(group.id) else { continue }
            if let box = correctBox(forOrder: group.order) {
                groupCollectionKey[group.id] = box.id
            }
        }

        // Fix already-staged segments whose collectionKey was pinned before their box arrived
        var didFixStaged = false
        for i in staged.indices where staged[i].type != CaptureGroupType.box.rawValue {
            if let box = correctBox(forOrder: staged[i].order), staged[i].collectionKey != box.id {
                staged[i].collectionKey = box.id
                groupCollectionKey[staged[i].groupId] = box.id
                didFixStaged = true
            }
        }
        if didFixStaged { persistManifest() }

        // Keep currentCollectionKey = the highest-seq box (not just the most-recently-arrived one)
        if let latest = boxes.last { currentCollectionKey = latest.id }
    }

    // MARK: - Finalize one segment

    private func finalizeSegment(groupId: String) async {
        guard session.processingMode == .live, let config, let stagingDir,
              !finalizedGroups.contains(groupId),
              let group = session.groups.first(where: { $0.id == groupId }) else { return }
        finalizedGroups.insert(groupId)
        session.lockSettings()   // first finalize locks the session's settings
        // B8: snapshot the clear-generation BEFORE any await. Every await below (box-label OCR, LLM tagging,
        // the off-main file write) suspends for seconds; if Clear runs during any of them, `clearGeneration`
        // advances and each post-await guard bails us out cleanly. No await has happened yet at this point.
        let startedGeneration = clearGeneration

        let collectionKey = groupCollectionKey[groupId] ?? (group.type == .box ? group.id : currentCollectionKey)
        setPhase(groupId, .tagging)

        // Await the OCR results for this segment's pages (started on arrival). A per-item "rotate & re-run"
        // override forces this group's output rotation (the re-OCR itself doesn't re-detect it).
        var results: [OCRResult] = []
        var texts: [String] = []
        let rotationOverride = groupOCROverride[groupId]?.rotation
        for photo in group.photos {
            var r = await pageTasks[photo.id]?.value
                ?? OCRResult(text: nil, classification: nil, errorMessage: "OCR not started", errorCode: nil)
            if let rot = rotationOverride {
                r = OCRResult(text: r.text, classification: r.classification,
                              rotationDegrees: ((rot % 360) + 360) % 360,
                              errorMessage: r.errorMessage, errorCode: r.errorCode)
            }
            results.append(r)
            texts.append(r.text ?? "")
        }
        // B8: the per-page OCR awaits above can suspend for seconds (box-label OCR). If Clear ran in that
        // window the session was reset — bail before touching any (now-cleared) state or making the LLM call.
        guard clearGeneration == startedGeneration else { return }
        groupOCROverride[groupId] = nil   // consumed

        // Tags: Mac subjects skip the LLM; automatic mode calls the LLM; box/folder → color tag.
        let mac = session.macTags[groupId]
        let segment = DocumentSegment(pdfURLs: group.photos.map { $0.url },
                                      isBox: group.type == .box, isFolder: group.type == .folder, texts: texts)
        var tags = await computeTags(group: group, segment: segment, mac: mac, config: config)
        // Phone's in-the-room date wins (Mac override beats the phone value).
        if let y = mac?.year ?? group.year { tags.year = String(y); tags.dateUncertain = false }
        if let m = mac?.month ?? group.month, let mt = GeneratedTags.monthTag(m) {
            tags.month = mt
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
        let outputImageFile = config.outputImageFile, pdfImageMB = config.pdfImageMB, exportedImageMB = config.exportedImageMB, textColumns = config.textColumns
        let stampUnread = config.taggingMode.stampsUnread

        // B8: `computeTags` above may have suspended on an LLM tagging call. Re-check BEFORE writing the
        // output PDF, so a Clear during OCR/tagging bails here and never leaves an orphan PDF in the cleared
        // session's `_processed/`. (The write is the last unavoidable-before-check step; see the guard below.)
        guard clearGeneration == startedGeneration else { return }

        let outcome = await Task.detached(priority: .userInitiated) { () -> StagedSegment in
            Self.writeSegmentFiles(groupId: groupId, type: gType, collectionKey: collectionKey, order: gOrder,
                                   pages: pages, baseTags: baseTags, doMerge: doMerge, model: model,
                                   gatewayName: gatewayName, stagingDir: stagingDir, writeJSON: writeJSON,
                                   jsonTags: jsonTags, texts: texts,
                                   boxLabelText: gType == .box ? texts.first : nil,
                                   outputImageFile: outputImageFile, pdfImageMB: pdfImageMB,
                                   exportedImageMB: exportedImageMB, textColumns: textColumns,
                                   stampUnread: stampUnread)
        }.value

        // B8: the off-main write itself can straddle a Clear. If the session was cleared while it ran, do NOT
        // re-add staged/retained state, set a phase, or persist a stale one-entry manifest — the pane must
        // stay empty. Bailing deletes nothing (Recovery Directive): any file just written stays recoverable
        // in `_processed/`; we only decline to re-populate cleared in-memory state.
        guard clearGeneration == startedGeneration else { return }

        staged.append(outcome)
        // Retain the write inputs so an end-of-session rotation review can regenerate this segment.
        retained[groupId] = RetainedSegment(
            groupId: groupId, type: gType, collectionKey: collectionKey, order: gOrder,
            pages: pages, baseTags: baseTags, doMerge: doMerge, model: model, gatewayName: gatewayName,
            writeJSON: writeJSON, jsonTags: jsonTags, texts: texts,
            boxLabelText: gType == .box ? texts.first : nil,
            outputImageFile: outputImageFile, pdfImageMB: pdfImageMB,
            exportedImageMB: exportedImageMB, textColumns: textColumns,
            stampUnread: stampUnread)
        persistManifest()
        for p in group.photos { pageTasks[p.id] = nil }   // free memory
        // A1 — discriminated failure taxonomy (labeling ONLY; the data-safety gate is unchanged). The
        // `outcome` (pdfURLs / pagesComplete) already fed the StagedSegment above, and finalize/deletion
        // keys off `executePlans`' filedGroupIds + `pagesComplete`, NEVER off `failedGroupIds`. So splitting
        // the label here — and un-conflating the filed image-only doc into `.succeededNoText` — cannot change
        // when/what gets deleted; it only fixes what the operator sees and what bulk-retry re-runs.
        let producedOutput = !outcome.pdfURLs.isEmpty
        let pagesComplete = outcome.pagesComplete ?? true
        let anyText = results.contains { $0.text != nil }
        let firstError = results.first(where: { $0.errorMessage != nil })
        if !producedOutput {
            // No PDF at all (incl. a true document OCR-empty with no usable PDF). Retryable; sources kept.
            markFailed(groupId, .noOutput, firstError)
        } else if !pagesComplete {
            // Some page produced no PDF → incomplete; finalize won't file it, so it never partially deletes
            // a multi-page segment's sources. Retryable.
            markFailed(groupId, .incompleteOutput, firstError)
        } else if gType == .document && !anyText {
            // Complete image-only PDF (every page produced a PDF, but no OCR text). It IS staged and WILL be
            // filed by executePlans exactly as before — this is a WARNING, not a hard failure. Drop it from
            // failedGroupIds so bulk "Retry failed" stops over-counting a successfully-filed doc.
            failedGroupIds.remove(groupId)
            setStatusDetail(groupId, kind: nil, error: firstError)
            setPhase(groupId, .succeededNoText)
        } else {
            failedGroupIds.remove(groupId)
            setStatusDetail(groupId, kind: nil, error: nil)
            setPhase(groupId, .staged)
        }
        proceedToFinishIfReady()   // if the operator hit Finish mid-processing, this staged segment may be the last
    }

    /// Compute the segment's subject/color tags (may hit the LLM). Date/priority are layered on later.
    private func computeTags(group: CaptureGroup, segment: DocumentSegment,
                             mac: MacSegmentTags?, config: SessionProcessingConfig) async -> GeneratedTags {
        if group.type != .document {
            // Box/Folder → color tag (TagGenerator returns Box/Red or Folder/Purple with no LLM call).
            return await TagGenerator().generateTags(for: segment, nearbySegments: [], provider: config.provider,
                                                     model: config.model, thinkingLevel: nil, apiKey: config.apiKey,
                                                     vocabulary: [], gatewayConfig: config.gateway, localAgent: config.localAgent)
        }
        if let subs = mac?.subjects, !subs.isEmpty { return GeneratedTags(subjectTags: subs) }   // Mac-tagged → no LLM
        if config.taggingMode == .automatic {
            return await TagGenerator().generateTags(for: segment, nearbySegments: [], provider: config.provider,
                                                     model: config.model, thinkingLevel: nil, apiKey: config.apiKey,
                                                     vocabulary: config.tagVocabulary, gatewayConfig: config.gateway, localAgent: config.localAgent)
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
        let textColumns: Int
        /// Nil only for a legacy manifest that pre-dates this field. Rotation regeneration then uses
        /// the recovered session config, matching the old global-at-activation behavior.
        let stampUnread: Bool?

        // Custom decoder: decodeIfPresent for fields added after the original manifest so old staged
        // sessions remain recoverable. A nil legacy tag policy is resolved from the session config below.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            groupId = try c.decode(String.self, forKey: .groupId)
            type = try c.decode(CaptureGroupType.self, forKey: .type)
            collectionKey = try c.decode(String.self, forKey: .collectionKey)
            order = try c.decode(Int.self, forKey: .order)
            pages = try c.decode([PageWork].self, forKey: .pages)
            baseTags = try c.decode([String].self, forKey: .baseTags)
            doMerge = try c.decode(Bool.self, forKey: .doMerge)
            model = try c.decode(LLMModel.self, forKey: .model)
            gatewayName = try c.decodeIfPresent(String.self, forKey: .gatewayName)
            writeJSON = try c.decode(Bool.self, forKey: .writeJSON)
            jsonTags = try c.decode(GeneratedTags.self, forKey: .jsonTags)
            texts = try c.decode([String].self, forKey: .texts)
            boxLabelText = try c.decodeIfPresent(String.self, forKey: .boxLabelText)
            outputImageFile = try c.decode(Bool.self, forKey: .outputImageFile)
            pdfImageMB = try c.decode(Double.self, forKey: .pdfImageMB)
            exportedImageMB = try c.decode(Double.self, forKey: .exportedImageMB)
            textColumns = try c.decodeIfPresent(Int.self, forKey: .textColumns) ?? 1
            stampUnread = try c.decodeIfPresent(Bool.self, forKey: .stampUnread)
        }

        // Memberwise init (matches the synthesized one the callers already use).
        init(groupId: String, type: CaptureGroupType, collectionKey: String, order: Int,
             pages: [PageWork], baseTags: [String], doMerge: Bool, model: LLMModel, gatewayName: String?,
             writeJSON: Bool, jsonTags: GeneratedTags, texts: [String], boxLabelText: String?,
             outputImageFile: Bool, pdfImageMB: Double, exportedImageMB: Double, textColumns: Int,
             stampUnread: Bool) {
            self.groupId = groupId; self.type = type; self.collectionKey = collectionKey; self.order = order
            self.pages = pages; self.baseTags = baseTags; self.doMerge = doMerge; self.model = model
            self.gatewayName = gatewayName; self.writeJSON = writeJSON; self.jsonTags = jsonTags
            self.texts = texts; self.boxLabelText = boxLabelText; self.outputImageFile = outputImageFile
            self.pdfImageMB = pdfImageMB; self.exportedImageMB = exportedImageMB; self.textColumns = textColumns
            self.stampUnread = stampUnread
        }
    }

    nonisolated private static func writeSegmentFiles(
        groupId: String, type: CaptureGroupType, collectionKey: String, order: Int,
        pages: [PageWork], baseTags: [String], doMerge: Bool, model: LLMModel, gatewayName: String?,
        stagingDir: URL, writeJSON: Bool, jsonTags: GeneratedTags, texts: [String], boxLabelText: String?,
        outputImageFile: Bool, pdfImageMB: Double, exportedImageMB: Double, textColumns: Int,
        stampUnread: Bool
    ) -> StagedSegment {
        let fm = FileManager.default
        let pdfGen = PDFGenerator()
        var pdfURLs: [URL] = []
        var imageURLs: [URL] = []

        for page in pages {
            let base = page.sourceURL.deletingPathExtension().lastPathComponent
            let stagedPDF = stagingDir.appendingPathComponent(base + ".pdf")
            _ = try? pdfGen.generate(imageURL: page.sourceURL, result: page.result, model: model,
                                     outputURL: stagedPDF, originalFileName: page.sourceURL.lastPathComponent,
                                     gatewayDisplayName: gatewayName, pdfImageMB: pdfImageMB, textColumns: textColumns)
            // Only record a PDF we can PROVE is on disk. `generate` is `try?`, so a swallowed failure would
            // otherwise append a phantom URL — and finalize keys "safe to delete the source photo" off the
            // PDF actually reaching the destination. A phantom would let a never-written output masquerade as
            // filed, and the irreplaceable source would be deleted (the original data-loss bug). So skip a
            // page whose PDF didn't write: its source stays in the backup folder and the segment is surfaced
            // as failed (retryable) because it produced no output.
            guard fm.fileExists(atPath: stagedPDF.path) else { continue }
            var tagList = baseTags
            if let pr = page.priority, !tagList.contains(pr) { tagList.append(pr) }
            _ = try? MacOSTagger.applyTags(tagList, to: stagedPDF, stampUnread: stampUnread)
            pdfURLs.append(stagedPDF)

            // Two-file output: a .jpg next to its PDF, sized to the exported-image target + identical tags.
            if outputImageFile {
                let stagedImg = stagingDir.appendingPathComponent(base + ".jpg")
                if ImageEncoding.writeSizedJPEG(from: page.sourceURL, to: stagedImg, targetMB: exportedImageMB, rotationDegrees: page.result.rotationDegrees) {
                    _ = try? MacOSTagger.applyTags(tagList, to: stagedImg, stampUnread: stampUnread)
                    imageURLs.append(stagedImg)
                }
            }
        }

        // Did EVERY source page produce a PDF on disk? Computed BEFORE merge collapses `pdfURLs`. If a page's
        // generation was silently dropped above, the segment is incomplete — finalize will keep ALL its
        // sources (never delete a page whose output doesn't exist) and surface it as failed for retry.
        let pagesComplete = (pdfURLs.count == pages.count)

        // Segment JSON (documents only), written from source page names before any merge.
        var jsonURL: URL? = nil
        if writeJSON, type == .document, let firstPDF = pdfURLs.first {
            let jurl = firstPDF.deletingPathExtension().appendingPathExtension("json")
            writeSegmentJSON(pageURLs: pages.map { $0.sourceURL }, texts: texts, tags: jsonTags, to: jurl)
            if fm.fileExists(atPath: jurl.path) { jsonURL = jurl }   // only record it if it actually wrote
        }

        if doMerge, pdfURLs.count > 1 {
            let base = pdfURLs[0].deletingPathExtension().lastPathComponent
            let mergedURL = stagingDir.appendingPathComponent(base + "_merged.pdf")
            do {
                try pdfGen.mergeDocumentPDFs(sourcePDFs: pdfURLs, outputURL: mergedURL)
                var tagList = baseTags
                if let pr = pages.first?.priority, !tagList.contains(pr) { tagList.append(pr) }
                _ = try? MacOSTagger.applyTags(tagList, to: mergedURL, stampUnread: stampUnread)
                for u in pdfURLs { try? fm.removeItem(at: u) }
                pdfURLs = [mergedURL]
            } catch { /* keep the individual PDFs if merge fails */ }
        }

        return StagedSegment(groupId: groupId, type: type.rawValue, collectionKey: collectionKey, order: order,
                             pdfURLs: pdfURLs, imageURLs: imageURLs, jsonURL: jsonURL, boxLabelText: boxLabelText,
                             pagesComplete: pagesComplete)
    }

    /// Writes the metadata sidecar (OCR body + fields) via the shared `SegmentJSONBuilder`. This path
    /// is documents-only, so it passes no box/folder label format override.
    nonisolated private static func writeSegmentJSON(pageURLs: [URL], texts: [String], tags: GeneratedTags, to jsonURL: URL) {
        guard let data = SegmentJSONBuilder.buildData(fileURLs: pageURLs, texts: texts, tags: tags) else { return }
        try? data.write(to: jsonURL, options: .atomic)
    }

    nonisolated private static func ocrTask(
        imageURL: URL, provider: LLMProvider, model: LLMModel, thinkingLevel: ThinkingLevel?,
        apiKey: String, customPrompt: String?, imageScale: Double, gateway: GatewayConfig?,
        localAgent: LocalAgentConfig?, rotationMode: RotationMode, standardImageMB: Double
    ) -> Task<OCRResult, Never> {
        Task.detached(priority: .userInitiated) {
            await OCRProcessor.performOCRCall(
                imageURL: imageURL, provider: provider, model: model, thinkingLevel: thinkingLevel,
                apiKey: apiKey, previousText: nil, previousImageURL: nil,
                customPrompt: customPrompt, imageScale: imageScale, gatewayConfig: gateway,
                localAgent: localAgent, rotationMode: rotationMode, standardImageMB: standardImageMB)
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

    /// Mark a segment failed with a discriminated reason (labeling only — see finalizeSegment). Adds it to
    /// `failedGroupIds` (retry set) and records the reason for the shared row's failure line.
    private func markFailed(_ groupId: String, _ kind: FailureKind, _ error: OCRResult?) {
        failedGroupIds.insert(groupId)
        setStatusDetail(groupId, kind: kind, error: error)
        setPhase(groupId, .failed)
    }

    /// Record a segment's failure/label detail (reason + provider error) for the UI.
    private func setStatusDetail(_ groupId: String, kind: FailureKind?, error: OCRResult?) {
        guard let idx = statuses.firstIndex(where: { $0.id == groupId }) else { return }
        statuses[idx].failureKind = kind
        statuses[idx].errorMessage = error?.errorMessage
        statuses[idx].errorCode = error?.errorCode
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

    /// "Finish session" button entry point. Two jobs before the review can start:
    ///  1) RECOVER any document that never got a Mac tag card — one the operator ended but whose
    ///     completion signal never landed, OR never tapped End segment on — by force-completing all still-
    ///     open doc groups so their cards surface now. This replaces the removed phone "Finish" fallback.
    ///  2) WAIT for in-flight processing: if any segment is still OCR'ing/tagging (or a tag card is still
    ///     pending), don't proceed yet — otherwise those segments are missing from the rotation review.
    /// Once everything is staged, `proceedToFinishIfReady` runs `finishSession`.
    func requestFinish() {
        guard !showFinalizeSheet, !showRotationReview, !isFinalizing else { return }   // a finish is already in progress
        guard session.completeAllOpenDocGroups() else {
            // A prior Finish may already have armed the watchdog. Cancel it too; otherwise it could later
            // advance after this re-tap rolled a newly-open group's undurable completion back.
            pendingFinish = false
            session.statusMessage = "Could not save session completion — check the backup folder and try Finish again."
            return
        }
        let wasPending = pendingFinish
        pendingFinish = true
        if !wasPending { startFinishWatchdog() }   // one watchdog per pending-finish episode
        proceedToFinishIfReady()
    }

    /// While a Finish is pending, re-evaluate periodically so it auto-advances even when nothing else
    /// re-triggers it — in particular when a phone that was still sending goes silent and its heartbeat
    /// lapses to stale (`phonePendingActive` flips false at 20s) with no further event to notice it.
    private func startFinishWatchdog() {
        Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, self.pendingFinish else { return }
                self.proceedToFinishIfReady()
            }
        }
    }

    /// Abort a pending Finish (e.g. the operator hit Clear instead of resolving the surfaced cards), so the
    /// Finish button can't stay wedged disabled with nothing left to advance it.
    func cancelPendingFinish() { pendingFinish = false }

    /// The phone's un-sent count changed (a `POST /phone/status` heartbeat). Re-evaluate a pending Finish
    /// so it advances the moment the phone has drained (and processing is done).
    func phoneStatusChanged() { proceedToFinishIfReady() }

    /// Advance a pending Finish once no tag card is outstanding and nothing is still being processed.
    /// Called after each segment stages and whenever a card is resolved, so a Finish requested mid-run
    /// waits for processing to complete instead of dropping unstaged segments from the review.
    private func proceedToFinishIfReady() {
        guard pendingFinish else { return }
        // Only count segments that still EXIST — a status left at .ocr/.tagging for a group whose photos
        // were deleted (thumbnail X) or reclassified away (X-Replaces) can never resolve (no group → no tag
        // card, no finalizeSegment), so it must not block the finish forever. Finalized groups are .staged/.failed.
        let stillProcessing = statuses.contains { s in
            (s.phase == .ocr || s.phase == .tagging) && session.groups.contains { $0.id == s.id }
        }
        // Also wait while a FRESH phone heartbeat says it still has photos to send, so a segment whose pages
        // are all still in flight isn't omitted. A stale heartbeat (phone disconnected) does NOT block — the
        // Finish button stays tappable as the escape.
        guard session.pendingTagGroup == nil, !stillProcessing, !session.phonePendingActive else { return }
        pendingFinish = false
        finishSession()
    }

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
        // Legacy retained manifests had no per-run unread policy. Before this fix, activation set the
        // recovered session config on the global immediately before regeneration; this fallback preserves
        // that behavior while every new manifest carries the exact original value.
        let legacyStampUnread = config?.taggingMode.stampsUnread ?? true
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
                                           exportedImageMB: seg.exportedImageMB, textColumns: seg.textColumns,
                                           stampUnread: seg.stampUnread ?? legacyStampUnread)
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
    /// The output folder to file collections into, read LIVE from Settings at finalize time (not the
    /// session's locked config). The output folder is only used at the final move, so honoring a change
    /// made mid-session — via the Live Capture "Output folder" picker or Process Files — is safe and
    /// expected: both the "Add to" existing-folder list and the destination track the current choice.
    /// Falls back to the locked config's directory, then Downloads.
    private var currentOutputDirectory: URL {
        // Test isolation (data safety): the headless LiveCaptureTestDriver sets LIVECAPTURE_TESTOUT, so
        // finalize writes into an ISOLATED scratch folder and NEVER the operator's real output corpus. The
        // move reads THIS, not the driver's `config.outputDirectory`, so without this guard a test run would
        // silently file into the real folder. Env-only; unset in production. Mirrors LIVECAPTURE_TRANSPORT/
        // RELAYDIR overrides elsewhere.
        if let testOut = ProcessInfo.processInfo.environment["LIVECAPTURE_TESTOUT"], !testOut.isEmpty {
            return URL(fileURLWithPath: testOut)
        }
        if let path = UserDefaults.standard.string(forKey: DefaultsKeys.outputDirectory),
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return config?.outputDirectory
            ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func beginFinalize() {
        guard config != nil, !staged.isEmpty else { return }
        let existing = Self.existingCollectionFolders(in: currentOutputDirectory)
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
        guard config != nil, let stagingDir, !isFinalizing else { return }
        isFinalizing = true
        let outputDir = currentOutputDirectory   // live output folder (matches the "Add to" list built above)
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

            // DATA-SAFETY GATE (the never-lose-a-photo invariant). Delete a source photo ONLY for a segment
            // whose processed output actually REACHED its destination collection — `outcome.filedGroupIds`,
            // confirmed on disk. A segment whose PDF was missing (a swallowed generation failure) or whose
            // move failed is NOT filed: its source photos AND its staged outputs stay in the visible backup
            // folder, so an irreplaceable page is never lost — even when finalize "succeeds" with 0 files
            // moved (the original data-loss bug: a folder was created, nothing moved, every source deleted).
            // Deletions go to the Trash (recoverable), never a hard rm.
            let filedGroups = outcome.filedGroupIds
            let filedSources = Set(self.retained.values
                .filter { filedGroups.contains($0.groupId) }
                .flatMap { $0.pages.map { $0.sourceURL } })

            // Drop bookkeeping for the fully-filed segments only; keep any unfiled segment staged for retry.
            self.staged.removeAll { filedGroups.contains($0.groupId) }
            self.statuses.removeAll { filedGroups.contains($0.id) }
            for gid in filedGroups { self.retained[gid] = nil; self.finalizedGroups.remove(gid) }
            self.drafts.removeAll()

            if outcome.allFiled {
                // Everything landed → staging holds nothing recoverable. Trash it and reset the session.
                CaptureSession.trashOrRemove(stagingDir)
                self.startedPhotoIds.removeAll()
                self.rotationReviewPages.removeAll()
                self.currentCollectionKey = "__unfiled__"
                self.finalizeSummary = outcome.summary
            } else {
                // Partial/failed: KEEP the unfiled segments staged (their outputs remain in the backup
                // folder's `_processed`) and KEEP their source photos, for recovery/retry. Persist the
                // reduced manifest so a crash right now leaves a consistent state.
                self.persistManifest()
                let kept = self.staged.count
                if kept > 0 {
                    self.finalizeSummary = outcome.summary
                        + " ⚠️ \(kept) segment\(kept == 1 ? "" : "s") could NOT be filed — their original photos and processed files are KEPT in the Backup Folder (nothing deleted). Check the output folder (permissions / free space / a missing output), then Finish again or recover from the Backup Folder."
                } else {
                    // Every document filed, but a secondary file (an exported image or JSON sidecar) couldn't
                    // be moved. No source was deleted for it; the leftover sits in the Backup Folder.
                    self.finalizeSummary = outcome.summary
                        + " ⚠️ All documents were filed, but a secondary file (an image or JSON sidecar) couldn't be moved — check the output folder; the leftover is in the Backup Folder."
                }
            }
            // Clear ONLY the confirmed-filed source photos (to the Trash); every unfiled or straggler page
            // stays in the backup folder + Captured pane, recoverable.
            self.session.clearFiled(filedSources)
        }
    }

    /// Clear the "Finalized …" summary (called when new capture begins, or on a manual Clear).
    func clearFinalizeSummary() { if finalizeSummary != nil { finalizeSummary = nil } }

    /// Reconcile the Processing pane with a Captured-pane **Clear** (B1): reset the in-memory/UI state that
    /// drives the Processing list so both panes empty as one. This is the processing-side mirror of
    /// `CaptureSession.clear()` (which sends the received source photos to the Trash — recoverable).
    ///
    /// DATA SAFETY (Recovery Core Directive, unchanged): this is a **pure in-memory/UI reset** — it performs
    /// **no** on-disk deletion. Any already-staged processed output stays exactly where it was, in the
    /// visible backup folder's `_processed/` subfolder (recoverable in Finder), and the staging manifest is
    /// left untouched on disk. So Clear never hard-deletes a staged/un-filed page: it only forgets the
    /// segments in memory so the pane agrees with the (now-cleared) Captured pane. In-flight OCR `pageTasks`
    /// are dropped (their results are simply discarded); a fresh capture after Clear starts a new segment.
    func clearSessionState() {
        // B8: advance the generation so any in-flight `finalizeSegment` that suspended at an await before this
        // Clear bails at its next post-await guard instead of repopulating the just-cleared pane / writing a
        // stale manifest. And CANCEL each outstanding OCR task before dropping it, so its work stops rather
        // than running to completion after the session was cleared (its result is discarded either way).
        clearGeneration &+= 1
        for task in pageTasks.values { task.cancel() }
        statuses.removeAll()
        staged.removeAll()
        failedGroupIds.removeAll()
        finalizedGroups.removeAll()
        startedPhotoIds.removeAll()
        retained.removeAll()
        groupCollectionKey.removeAll()
        groupOCROverride.removeAll()
        pageTasks.removeAll()
        rotationReviewPages.removeAll()
        currentCollectionKey = "__unfiled__"
        pendingFinish = false
        clearFinalizeSummary()
    }

    private struct MovePlan: Sendable {
        let folder: URL; let name: String; let appending: Bool; let segments: [StagedSegment]
    }

    /// Outcome of moving staged files into their collection folders. `filedGroupIds` is the set of segments
    /// whose *every* PDF output actually reached its destination collection — the ONLY segments whose source
    /// photos are safe to delete. `failedMoves > 0` (a real move error) or a segment absent from
    /// `filedGroupIds` (its output was missing/failed) means the caller must KEEP that segment's staging +
    /// source photos. `allFiled` is true only when every staged segment fully filed with no failures.
    private struct FinalizeOutcome: Sendable {
        let summary: String
        let failedMoves: Int
        let movedFiles: Int
        let filedGroupIds: Set<String>
        let allFiled: Bool
    }

    private enum MoveResult { case moved, absent, failed }

    nonisolated private static func executePlans(_ plans: [MovePlan]) -> FinalizeOutcome {
        let fm = FileManager.default
        var movedFiles = 0
        var failedMoves = 0
        var filedGroupIds = Set<String>()
        var totalSegments = 0
        // Move one file; returns true iff it actually LANDED at the destination — so a segment can tell
        // whether ALL of its authoritative PDF outputs were filed (the gate for deleting its source photo).
        func doMove(_ src: URL, to dest: URL) -> Bool {
            switch move(src, to: dest, fm: fm) {
            case .moved: movedFiles += 1; return true
            case .absent: return false           // nothing staged for this slot (e.g. a page whose gen failed)
            case .failed: failedMoves += 1; return false   // a real move error — the output is still in staging
            }
        }
        for plan in plans {
            try? fm.createDirectory(at: plan.folder, withIntermediateDirectories: true)
            // ALWAYS continue numbering from the folder's existing max (not only when appending). A "new
            // collection" whose folder already holds numbered files — e.g. a Finish-again retry after a
            // partial finalize, or the operator reusing a name — must NOT restart at 00001 and collide with
            // (and overwrite) an already-filed file. `appending` no longer affects numbering; both paths are
            // now collision-proof.
            var seq = CollectionNumbering.highestLeadingNumber(in: plan.folder)
            for seg in plan.segments {
                totalSegments += 1
                // An INCOMPLETE segment (a source page produced no PDF) is NEVER filed: skip it entirely so no
                // partial output scatters to the destination and none of its source pages are deleted. Its
                // staged files stay in `_processed` and it's marked failed (retryable) in finalizeSegment.
                if seg.pagesComplete == false { continue }
                // PDFs are the authoritative output. A segment counts as "filed" (its source photos safe to
                // delete) ONLY if it staged at least one PDF and EVERY one reached the destination. Exported
                // images / JSON are secondary and do NOT gate deletion.
                var pdfExpected = 0, pdfLanded = 0
                var firstNum: Int?
                if seg.imageURLs.isEmpty {
                    // One-file output (PDF only): number by PDF (a merged doc is already a single PDF).
                    for pdf in seg.pdfURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        pdfExpected += 1
                        if doMove(pdf, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).pdf")) { pdfLanded += 1 }
                    }
                } else if seg.pdfURLs.count == 1 && seg.imageURLs.count > 1 {
                    // Merged multi-page document: one PDF for many page images. Number each image, then the
                    // single merged PDF at the first number.
                    for img in seg.imageURLs {
                        seq += 1
                        if firstNum == nil { firstNum = seq }
                        let numStr = String(format: "%05d", seq)
                        let ext = img.pathExtension.isEmpty ? "jpg" : img.pathExtension
                        _ = doMove(img, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).\(ext)"))
                    }
                    if let fn = firstNum, let pdf = seg.pdfURLs.first {
                        pdfExpected += 1
                        if doMove(pdf, to: plan.folder.appendingPathComponent("\(String(format: "%05d", fn)) \(plan.name).pdf")) { pdfLanded += 1 }
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
                            _ = doMove(img, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).\(ext)"))
                        }
                        pdfExpected += 1
                        if doMove(pdf, to: plan.folder.appendingPathComponent("\(numStr) \(plan.name).pdf")) { pdfLanded += 1 }
                    }
                }
                if let json = seg.jsonURL, let fn = firstNum {
                    let jf = plan.folder.appendingPathComponent("JSON Output", isDirectory: true)
                    try? fm.createDirectory(at: jf, withIntermediateDirectories: true)
                    _ = doMove(json, to: jf.appendingPathComponent("\(String(format: "%05d", fn)) \(plan.name).json"))
                }
                // Filed iff it produced ≥1 PDF and ALL of them landed. (No PDF → never filed → source kept.)
                if pdfExpected > 0 && pdfLanded == pdfExpected { filedGroupIds.insert(seg.groupId) }
            }
        }
        let allFiled = failedMoves == 0 && filedGroupIds.count == totalSegments
        let summary = "Finalized \(plans.count) collection\(plans.count == 1 ? "" : "s") · \(movedFiles) files moved."
        return FinalizeOutcome(summary: summary, failedMoves: failedMoves, movedFiles: movedFiles,
                               filedGroupIds: filedGroupIds, allFiled: allFiled)
    }

    /// Test-only ($0, no OCR/session): run the finalize move/gate on synthetic staged files so a headless
    /// driver can assert the data-safety invariant — a segment whose PDF is MISSING must NOT be reported as
    /// filed (otherwise finalize would delete its irreplaceable source). Mirrors what `finalize` consumes.
    nonisolated static func _recoveryTestFinalizeMove(
        _ plans: [(folder: URL, name: String, appending: Bool,
                   segments: [(groupId: String, pdfURLs: [URL], imageURLs: [URL], jsonURL: URL?, complete: Bool)])]
    ) -> (movedFiles: Int, failedMoves: Int, filedGroupIds: Set<String>, allFiled: Bool) {
        let mapped: [MovePlan] = plans.map { p in
            MovePlan(folder: p.folder, name: p.name, appending: p.appending,
                     segments: p.segments.map { s in
                         StagedSegment(groupId: s.groupId, type: CaptureGroupType.document.rawValue,
                                       collectionKey: s.groupId, order: 0, pdfURLs: s.pdfURLs,
                                       imageURLs: s.imageURLs, jsonURL: s.jsonURL, boxLabelText: nil,
                                       pagesComplete: s.complete) })
        }
        let o = executePlans(mapped)
        return (o.movedFiles, o.failedMoves, o.filedGroupIds, o.allFiled)
    }

    /// Legacy staging-manifest migration (KNOWN_ISSUES #1 — "rotation review skips legacy-manifest segments").
    /// A **legacy** manifest is the bare `[StagedSegment]` array written before per-segment `retained` inputs
    /// were persisted (pre-`c0312f4`): it restores `staged` but carries **no** `retained`, so `finishSession`
    /// — which builds the rotation review from `retained.values` — would silently EXCLUDE those segments from
    /// the review. We can't safely regenerate a legacy segment in place (its original `rotationDegrees` is
    /// gone; seeding 0° would UN-rotate an auto-rotated page — strictly worse), so instead we DROP each such
    /// segment and let the normal resume path re-process it from scratch (re-OCR + re-tag → a proper
    /// `retained` → a COMPLETE rotation review).
    ///
    /// SAFETY (Recovery Core Directive): only drop a segment we can actually re-process — one whose source
    /// photos ALL still exist (`sourcesPresent(groupId)`). If any source is gone (e.g. the operator hit Clear
    /// before recovering), KEEP the legacy segment as-is (staged, un-reviewable — today's behavior) rather
    /// than delete regenerable output we can no longer rebuild. A dropped segment's stale staged output is
    /// deleted here so it isn't orphaned on disk; the raw sources stay in the visible backup folder, so a
    /// dropped-then-not-yet-reprocessed segment is always recoverable. Returns the segments to KEEP (restore
    /// into `staged`) plus the output files actually deleted (so the $0 self-test can assert on-disk effects).
    nonisolated static func migrateLegacyManifestSegments(
        _ legacy: [StagedSegment], sourcesPresent: (String) -> Bool
    ) -> (keep: [StagedSegment], deleted: [URL]) {
        let fm = FileManager.default
        var keep: [StagedSegment] = []
        var deleted: [URL] = []
        for s in legacy {
            guard sourcesPresent(s.groupId) else { keep.append(s); continue }   // no sources → can't regen → keep
            for u in s.pdfURLs where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u); deleted.append(u) }
            for u in s.imageURLs where fm.fileExists(atPath: u.path) { try? fm.removeItem(at: u); deleted.append(u) }
            if let j = s.jsonURL, fm.fileExists(atPath: j.path) { try? fm.removeItem(at: j); deleted.append(j) }
        }
        return (keep, deleted)
    }

    /// Move `src` to `dest`, reporting the outcome so the caller can tell a real failure (output stuck in
    /// staging) apart from a nothing-to-move slot. A missing source is `.absent`, not `.failed`.
    nonisolated private static func move(_ src: URL, to dest: URL, fm: FileManager) -> MoveResult {
        guard fm.fileExists(atPath: src.path) else { return .absent }
        // Overwriting an existing destination is now collision-proof (numbering continues from the folder's
        // max), so this should be unreachable in practice — but if a name ever does collide, send the old
        // file to the Trash (recoverable), never a hard delete.
        if fm.fileExists(atPath: dest.path) { CaptureSession.trashOrRemove(dest, fm) }
        do { try fm.moveItem(at: src, to: dest); return .moved } catch { return .failed }
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
