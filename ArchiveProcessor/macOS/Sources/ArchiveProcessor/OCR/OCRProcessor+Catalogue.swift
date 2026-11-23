import ArchiveCore
import Foundation
import PDFKit

extension OCRProcessor {
    nonisolated static var pendingCatalogueURL: URL {
        pendingRunURL.deletingLastPathComponent().appendingPathComponent("pending_catalogue.json")
    }

    nonisolated static func savedCatalogueRun() -> ProcessorCatalogueRun? {
        try? ProcessorCatalogueRun.load(from: pendingCatalogueURL)
    }

    func beginCatalogueRun(outputRoot: URL, sources: [URL], resuming: Bool = false,
                           confirmResume: () -> Bool = { true }) async -> Bool {
        do {
            let lease = try ProcessorCatalogueRun.Lease(journal: Self.pendingCatalogueURL)
            guard confirmResume() else {
                checkForPendingBatch()
                statusMessage = "The saved run changed before it could be resumed. Check the interrupted-run controls again."
                return false
            }
            catalogueDocumentFields = [:]
            catalogueMergeInputs = [:]
            catalogueFilingWarning = ""
            if let saved = Self.savedCatalogueRun() {
                let originalPaths = saved.sources.map { $0.standardizedFileURL.path }
                guard resuming, saved.files == nil, saved.outputRoot.path == outputRoot.standardizedFileURL.path,
                      sources.map({ $0.standardizedFileURL.path }) == originalPaths else {
                    checkForPendingBatch()
                    statusMessage = "A Process Files working copy is still saved. Resume it before starting another run."
                    return false
                }
                catalogueRun = saved
                catalogueRunLease = lease
                return true
            }
            guard !Self.workingOutputOccupied(Self.pendingCatalogueURL) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if !resuming, [Self.pendingRunURL, Self.pendingBatchURL, Self.pendingMixedPDFURL].contains(where: Self.workingOutputOccupied) {
                checkForPendingBatch()
                statusMessage = "An interrupted run is still saved. Resume it before starting another run."
                return false
            }
            let intake = SettingsLayerStore.shared.keepsPreservationCopies
                ? try await PDFGenerator.runWorker(priority: .utility) {
                    var verified: [URL: ProcessorPreservationFiling.Intake] = [:]
                    for source in Set(sources) {
                        try Task.checkCancellation()
                        do {
                            verified[source] = try ProcessorPreservationFiling.Intake(url: source, resolveSelectedLink: true)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw PreservationIntakeFailure(filename: source.lastPathComponent)
                        }
                    }
                    try Task.checkCancellation()
                    return verified
                } : nil
            catalogueRun = try ProcessorCatalogueRun.create(outputRoot: outputRoot, sources: sources,
                                                            journal: Self.pendingCatalogueURL, preservationIntake: intake)
            catalogueRunLease = lease
            return true
        } catch {
            checkForPendingBatch()
            statusMessage = "Could not save the catalogue filing state: \(error.localizedDescription)"
            return false
        }
    }

    private struct PreservationIntakeFailure: LocalizedError {
        let filename: String
        var errorDescription: String? { "Could not verify the full-resolution original for “\(filename)”. Check that the source is available, then try again." }
    }

    func rememberCatalogueFields(_ tags: GeneratedTags, segment: DocumentSegment,
                                 dateIsUserSet: Bool = false, subjectsAreUserSet: Bool = false,
                                 dating: DateRoute.Decision? = nil, itemFields: ItemFieldResult? = nil,
                                 entities: EntityResult? = nil) {
        guard catalogueRun != nil else { return }
        let type: ItemType? = segment.isBox ? .box : segment.isFolder ? .folder : nil
        let fields = ProcessorCatalogueRecord.documentFields(tags: tags, type: type, dateIsUserSet: dateIsUserSet,
                                                             subjectsAreUserSet: subjectsAreUserSet, dating: dating,
                                                             itemFields: itemFields, entities: entities)
        for source in segment.pdfURLs { catalogueDocumentFields[source] = fields }
    }

    private struct DraftFile: Sendable {
        let pdf: URL
        let sources: [URL]
        let destination: URL
        let identity: CataloguePDFIdentity
        let document: ProcessorCatalogueRecord.Document
        let fileFields: ProcessorCatalogueRecord.FileFields
        let exports: [ProcessorCatalogueRun.Export]
        let preOCRed: Bool
        let mergeInputs: [CatalogueMergeInput]?
        let preservationIntake: [URL: ProcessorPreservationFiling.Intake]?
    }

    /// Reserve final destinations and prepare derivative copies after review, then freeze the whole plan
    /// before publishing any member. Working PDFs remain usable for a local filing retry.
    func finishCatalogueRun(organizing: Bool, preOCRed: Bool, exportingImages: Bool,
                            stampsUnread: Bool) async -> [URL: URL]? {
        guard var run = catalogueRun else { return [:] }
        do {
            if run.files == nil {
                run.inputJournalDigests = try catalogueInputJournalDigests(for: run)
                let drafts = try catalogueDrafts(run: run, organizing: organizing, preOCRed: preOCRed,
                                                 exportingImages: exportingImages, stampsUnread: stampsUnread)
                let workingRoot = run.workingRoot
                let outputRoot = run.outputRoot
                run.files = try await PDFGenerator.runWorker(priority: .utility) {
                    try Self.prepareCatalogueFiles(drafts, workingRoot: workingRoot, outputRoot: outputRoot)
                }
                try run.save(to: Self.pendingCatalogueURL)
                catalogueRun = run
            }
            return try await completeCatalogueRun(run)
        } catch {
            checkForPendingBatch()
            statusMessage = "Catalogue filing needs attention. Working files are kept. \(error.localizedDescription)"
            isProcessing = false
            return nil
        }
    }

    func completeCatalogueRun(_ run: ProcessorCatalogueRun) async throws -> [URL: URL] {
        let unfiled = try await PDFGenerator.runWorker(priority: .utility) { try run.fileOutputs() }
        try Task.checkCancellation()
        let archivedBatch = try retireCatalogueInputJournals(for: run)
        try FileManager.default.removeItem(at: Self.pendingCatalogueURL)
        activePendingRun = nil
        activePendingBatch = nil
        activePendingMixedPDF = nil
        pendingRunInfo = nil
        pendingRunBackend = nil
        pendingBatchInfo = nil
        pendingMixedPDFInfo = nil
        let files = run.files ?? []
        let moves = Dictionary(uniqueKeysWithValues: files.map { ($0.workingPDF, $0.destination) })
        for file in files {
            for source in file.sources { outputURLMap[source] = file.destination }
        }
        catalogueFilingWarning = unfiled.isEmpty ? "" : " Optional exports were kept in \(run.workingRoot.path)."
        if let archivedBatch {
            catalogueFilingWarning += " Known batch results were filed. The interrupted submission record is saved at \(archivedBatch.path)."
        }
        if unfiled.isEmpty, run.hasWorkingDirectory { try? FileManager.default.removeItem(at: run.workingRoot) }
        catalogueRun = nil
        catalogueDocumentFields = [:]
        return moves
    }

    nonisolated static func catalogueWorkingRun(outputRoot: URL, sources: [URL]) -> ProcessorCatalogueRun? {
        guard let run = savedCatalogueRun(), run.outputRoot.path == outputRoot.standardizedFileURL.path else { return nil }
        let originals = Set(run.sources.map { $0.standardizedFileURL.path })
        return sources.allSatisfy { originals.contains($0.standardizedFileURL.path) } ? run : nil
    }

    nonisolated static func workingOutputOccupied(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// Older interrupted runs can still supply derived bytes. Keep their files where they were,
    /// and associate a new private working copy before tagging or replacing anything.
    func catalogueResumeOutput(_ previous: URL, for source: URL, in outputRoot: URL) -> URL {
        guard let run = catalogueRun, !run.contains(previous) else { return previous }
        let filename = previous.deletingPathExtension().lastPathComponent
        let working = uniqueOutputURL(baseName: filename, ext: "pdf", in: outputRoot, for: source)
        if !OutputFileSafety.isSameFile(previous, source), !OutputFileSafety.hasCatalogueIdentity(at: previous) {
            do {
                try run.copyPreOCRSource(previous, to: working)
                guard let copied = PDFDocument(url: working), copied.pageCount > 0 else {
                    try FileManager.default.removeItem(at: working)
                    return working
                }
            } catch {
                NSLog("[ArchiveProcessor] Saved working PDF copy could not be restored: %@", error.localizedDescription)
            }
        }
        return working
    }

    private func catalogueDrafts(run: ProcessorCatalogueRun, organizing: Bool, preOCRed: Bool,
                                 exportingImages: Bool, stampsUnread: Bool) throws -> [DraftFile] {
        let allowedSources = Set(run.sources)
        let work = outputURLMap.filter { allowedSources.contains($0.key) && run.contains($0.value) }
        var sourcesByPDF: [URL: [URL]] = [:]
        for job in jobs {
            if let pdf = work[job.sourceURL] { sourcesByPDF[pdf, default: []].append(job.sourceURL) }
        }
        var seen = Set<URL>()
        let distinct = jobs.compactMap { work[$0.sourceURL] }.filter { seen.insert($0).inserted }
        let finalSegments = segments.isEmpty && run.sources.count == jobs.count
            ? currentSegments(files: jobs.map(\.sourceURL)) : segments
        let jobBySource = Dictionary(jobs.map { ($0.sourceURL, $0) }, uniquingKeysWith: { first, _ in first })
        var segmentBySource: [URL: Int] = [:]
        for (index, segment) in finalSegments.enumerated() {
            for source in segment.pdfURLs where !reOCRSourceURLs.contains(source) {
                segmentBySource[source] = index
            }
        }
        var planned: [URL: [OutputFileSafety.ArtifactMove]] = [:]
        if organizing && !collectionSegments.isEmpty {
            try CollectionSegmenter().organizeOutput(
                collections: collectionsOutsideTrees, outputDirectory: run.outputRoot, outputURLMap: outputURLMapOutsideTrees,
                moveSiblingImages: exportingImages, exportedImageMap: exportedImageMap
            ) { pdf, artifacts in
                planned[pdf] = artifacts
            }
        }

        let identities = Dictionary(uniqueKeysWithValues: distinct.map {
            ($0, CataloguePDFIdentity(fileID: UUID(), contentRevision: UUID()))
        })
        var owners: [URL: (UUID, UUID)] = [:]
        for pdf in distinct {
            guard let source = sourcesByPDF[pdf]?.first, let fileID = identities[pdf]?.fileID else { continue }
            let key = segmentBySource[source].flatMap { finalSegments[$0].pdfURLs.first } ?? source
            if owners[key] == nil { owners[key] = (UUID(), fileID) }
        }
        var reserved = Set<String>()
        return try distinct.compactMap { pdf in
            guard let sources = sourcesByPDF[pdf], let first = sources.first, let identity = identities[pdf] else {
                return nil
            }
            let segmentIndex = segmentBySource[first]
            let segment = segmentIndex.map { finalSegments[$0] }
            let key = segment?.pdfURLs.first ?? first
            guard let (documentID, ownerID) = owners[key] else { return nil }
            let tags = appliedGeneratedTags[first] ?? GeneratedTags()
            let type: ItemType? = segment?.isBox == true ? .box : segment?.isFolder == true ? .folder : nil
            var fields = catalogueDocumentFields[first]
                ?? ProcessorCatalogueRecord.documentFields(tags: tags, type: type, dateIsUserSet: false,
                                                           subjectsAreUserSet: false, dating: nil, itemFields: nil, entities: nil)
            if let segment {
                fields.itemType = type.map { .init($0.rawValue, origin: "user") }
                if segment.isBox || segment.isFolder {
                    fields.sentWith = nil
                }
            }
            let belongsToOwner = identity.fileID == ownerID
            let cover: ProcessorCatalogueRecord.DocumentReference? = belongsToOwner
                && enclosureDateReviews[first]?.manual?.rejectedCover != true
                ? segmentIndex.flatMap { Self.validCoverIndex(of: $0, in: finalSegments) }
                    .flatMap { finalSegments[$0].pdfURLs.first }
                    .flatMap { owners[$0] }
                    .map { .init(documentID: $0.0, ownerFileID: $0.1) }
                : nil
            let segmentJobs = sources.compactMap { jobBySource[$0] }
            let manualQuality = (taggingMode == .human || taggingMode == .autoDate) && appliedGeneratedTags[first] != nil
            let quality = manualQuality ? DocumentTags.qualityTag(for: tags.quality) ?? "Q0"
                : segmentJobs.flatMap(\.appliedTags).first(where: DocumentTags.isRatingToken)
            let failed = segmentJobs.contains { $0.status == .failed }
            var fileFields = ProcessorCatalogueRecord.fileFields(tags: tags, quality: quality, unread: stampsUnread, failed: failed)
            if passSourceTags {
                let copiedTags = DocumentTags.parse(raw: jobBySource[first]?.appliedTags ?? [], labelNumber: nil)
                ProcessorCatalogueRecord.applySourceTags(copiedTags, document: &fields, file: &fileFields)
            }
            let document = ProcessorCatalogueRecord.Document(id: documentID, ownerFileID: ownerID,
                                                             fields: belongsToOwner ? fields : nil, enclosedWith: cover)
            let destination: URL
            let exports: [ProcessorCatalogueRun.Export]
            if let artifacts = planned[pdf], let target = artifacts.first(where: { $0.source == pdf })?.destination {
                destination = target
                exports = artifacts.filter { $0.source != pdf }.map { .init(prepared: $0.source, destination: $0.destination) }
            } else {
                let json = pdf.deletingPathExtension().appendingPathExtension("json")
                let hasJSON = FileManager.default.fileExists(atPath: json.path)
                let desired = try catalogueOutputFolder(for: first, in: run.outputRoot)
                    .appendingPathComponent(pdf.lastPathComponent)
                destination = OutputFileSafety.reserveUniqueDestination(preferred: desired, reservedPaths: &reserved,
                                                                        companionExtension: hasJSON ? "json" : nil,
                                                                        reserveCatalogueCompanion: true)
                let images = sources.compactMap { exportedImageMap[$0] }
                let base = destination.deletingPathExtension()
                var optional: [ProcessorCatalogueRun.Export] = hasJSON
                    ? [.init(prepared: json, destination: base.appendingPathExtension("json"))] : []
                for (index, image) in images.enumerated() {
                    let stem = images.count == 1 ? base.lastPathComponent : "\(base.lastPathComponent)-\(index + 1)"
                    let desiredImage = base.deletingLastPathComponent()
                        .appendingPathComponent(stem).appendingPathExtension(image.pathExtension)
                    let target = OutputFileSafety.reserveUniqueDestination(preferred: desiredImage, reservedPaths: &reserved)
                    optional.append(.init(prepared: image, destination: target))
                }
                exports = optional
            }
            guard exports.allSatisfy({ run.contains($0.prepared) }) else { throw CocoaError(.fileWriteInvalidFileName) }
            return DraftFile(pdf: pdf, sources: sources, destination: destination, identity: identity,
                             document: document, fileFields: fileFields, exports: exports, preOCRed: preOCRed,
                             mergeInputs: catalogueMergeInputs[pdf], preservationIntake: run.preservationIntake)
        }
    }

    private func catalogueOutputFolder(for source: URL, in root: URL) throws -> URL {
        let path = source.standardizedFileURL.path
        guard let relative = outputSubfolders[path],
              let components = ContainerTree.components(ofRelativePath: relative) else { return root }
        let target = components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }
        do {
            try ProcessorCatalogueFiling.prepareDirectory(target, in: root)
            return target
        } catch let error as POSIXError where error.code == .ENOTDIR || error.code == .ELOOP {
            try ProcessorCatalogueFiling.prepareDirectory(root, in: root)
            if !outputsOutsideTheirTree.contains(path) { outputsOutsideTheirTree.append(path) }
            return root
        }
    }

    struct CatalogueMergeInput: Sendable {
        let intake: URL
        let derivative: URL
    }

    nonisolated private static func preservationPages(for draft: DraftFile,
                                                       pages: [ProcessorCatalogueRecord.SourcePage],
                                                       intake: [URL: ProcessorPreservationFiling.Intake])
        throws -> [ProcessorPreservationFiling.LogicalPage] {
        func pagesForSource(_ url: URL, range: ArraySlice<ProcessorCatalogueRecord.SourcePage>)
            throws -> [ProcessorPreservationFiling.LogicalPage] {
            guard let original = intake[url] else { throw PreservationCopy.Failure.unverified }
            var physical = 0
            return range.enumerated().map { index, page in
                let originalIndex = original.source.format != .pdf ? 0 : draft.preOCRed ? physical : index
                physical += page.roles.count
                return .init(source: original, originalPageIndex: originalIndex)
            }
        }

        if let merge = draft.mergeInputs {
            var offset = 0
            let result = try merge.flatMap { contribution in
                guard let part = PDFDocument(url: contribution.derivative) else {
                    throw PDFError.sourceUnreadable(contribution.derivative)
                }
                let count = PDFPageRole.roles(of: part).filter { $0 != .text }.count
                guard count > 0, count <= pages.count - offset else { throw PreservationCopy.Failure.unverified }
                defer { offset += count }
                return try pagesForSource(contribution.intake, range: pages[offset..<(offset + count)])
            }
            guard offset == pages.count else { throw PreservationCopy.Failure.unverified }
            return result
        }
        guard draft.sources.count == 1, let source = draft.sources.first else { throw PreservationCopy.Failure.unverified }
        return try pagesForSource(source, range: pages[...])
    }

    nonisolated private static func prepareCatalogueFiles(_ drafts: [DraftFile], workingRoot: URL,
                                                          outputRoot: URL) throws -> [ProcessorCatalogueRun.File] {
        let rootInstance = UUID()
        return try drafts.map { draft in
            try Task.checkCancellation()
            guard let pdf = PDFDocument(url: draft.pdf), pdf.pageCount > 0 else { throw PDFError.sourceUnreadable(draft.pdf) }
            var sourcePages: [ProcessorCatalogueRecord.SourcePage] = []
            let suiteHeader = draft.preOCRed ? PDFHeaderParser.extract(draft.pdf) : nil
            let hasSuiteProvenance = suiteHeader?.textPages.contains { $0.header?.provenance != nil } == true
            if draft.preOCRed && !hasSuiteProvenance {
                sourcePages = (0..<pdf.pageCount).map { _ in .init(roles: ["page"]) }
            } else {
                let roles = PDFPageRole.roles(of: pdf)
                for index in roles.indices where roles[index] != .text {
                    var rolesForSource = [roles[index].rawValue]
                    if roles[index] == .image, roles.indices.contains(index + 1), roles[index + 1] == .text {
                        rolesForSource.append(PDFPageRole.text.rawValue)
                    }
                    sourcePages.append(.init(roles: rolesForSource))
                }
            }
            guard sourcePages.reduce(0, { $0 + $1.roles.count }) == pdf.pageCount else {
                throw PDFError.sourceUnreadable(draft.pdf)
            }
            let preservation = try draft.preservationIntake.map { intake in
                let inputs = try Self.preservationPages(for: draft, pages: sourcePages, intake: intake)
                return try ProcessorPreservationFiling(fileID: draft.identity.fileID, pages: sourcePages, inputs: inputs)
            }
            let data = try ProcessorCatalogueRecord(identity: draft.identity, sourcePages: sourcePages,
                                                      document: draft.document, fileFields: draft.fileFields,
                                                      preservationManifestSHA256: preservation?.manifest.digest()).encoded()
            let prepared = workingRoot.appendingPathComponent(draft.identity.fileID.uuidString + ".prepared.pdf")
            let bytes = try SearchableArchival.catalogueCopy(of: draft.pdf, identity: draft.identity)
            try bytes.write(to: prepared, options: .withoutOverwriting)
            try OutputFileSafety.copyExtendedAttributes(from: draft.pdf, to: prepared)
            try ProcessorCatalogueRun.flushFileAndParent(prepared)
            let filing = try ProcessorCatalogueFiling(operationID: draft.identity.fileID, root: outputRoot,
                                                      rootInstanceID: rootInstance, destination: draft.destination)
            return ProcessorCatalogueRun.File(workingPDF: draft.pdf, prepared: prepared, sources: draft.sources,
                                              destination: draft.destination, record: data, filing: filing, exports: draft.exports,
                                              preservation: preservation)
        }
    }
}
