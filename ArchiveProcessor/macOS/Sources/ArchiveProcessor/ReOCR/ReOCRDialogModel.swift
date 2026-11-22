import ArchiveCore
import Foundation

// MARK: - Improve OCR: the dialog's state, without views (W44.reocr-processor)

/// What the Improve OCR dialog shows and decides (`SPEC/improve-ocr.md` §6), kept apart from its views so
/// it can be tested headless: each file's eligibility and current reader, each page's Kind (its header's, or the
/// person's choice; a page with neither must be given one), the pages grouped by Kind, the ranked readers for each group
/// and the one chosen, the estimate, and the run that sends every page to its group's reader. Changing a Kind re-groups
/// and re-ranks at once; nothing is read or spent until `run`, which only the person's explicit action calls.
@MainActor
final class ReOCRDialogModel {
    struct FileEntry: Identifiable, Sendable {
        let id: String
        let url: URL
        /// The pairs, or why the file cannot be improved in place (the separate-output route is the one for it).
        let eligibility: Result<[ReOCRPairs.Pair], ReOCRPairs.Refusal>
        /// W47.wh-yolo-scans-reocr: its collection's detector for scanned newspapers, which its pages are read with.
        let scanDetector: NewspaperDetector

        func pair(at index: Int) -> ReOCRPairs.Pair? {
            (try? eligibility.get())?.first { $0.textIndex == index }
        }
    }

    struct Group: Sendable {
        let kind: OCRPageKind?
        let pages: [ReOCRPageChoice]
        /// Nil for the pages with no Kind yet.
        let ranking: ReOCRRanking?
    }

    private(set) var files: [FileEntry] = []
    private(set) var pages: [ReOCRPageChoice] = []
    /// The chosen row per Kind; defaults to the ranking's suggestion.
    private var chosen: [OCRPageKind: String] = [:]

    let table: SettingsRouteTable
    let pairs: OCRPairMatrix?
    let resources: SettingsResources
    let staysOnMac: Bool
    /// W46.training-optout-run: the files' collections say their pages must not train a provider's models.
    let noTraining: Bool
    private let selectedPairs: [URL: [Int]]
    private let scanDetectors: [URL: NewspaperDetector]

    /// `selectedPairs` keeps, for a file the Reader named pairs for, only those pairs (0-based); a pair past the end of
    /// the file is ignored.
    init(selectedPairs: [URL: [Int]] = [:], table: SettingsRouteTable, pairs: OCRPairMatrix?,
         resources: SettingsResources, staysOnMac: Bool, noTraining: Bool = false,
         scanDetectors: [URL: NewspaperDetector] = [:]) {
        self.selectedPairs = selectedPairs
        self.table = table
        self.pairs = pairs
        self.resources = resources
        self.staysOnMac = staysOnMac
        self.noTraining = noTraining
        self.scanDetectors = scanDetectors
    }

    func loadFiles(_ urls: [URL], progress: (Int) -> Void = { _ in }) async {
        for (index, url) in urls.enumerated() {
            guard !Task.isCancelled else { return }
            let (file, choices) = await Self.readFile(url, selectedPairs: selectedPairs[url],
                                                     scanDetector: scanDetectors[url] ?? .ppDocLayoutV3)
            guard !Task.isCancelled else { return }
            files.append(file)
            pages.append(contentsOf: choices)
            progress(index + 1)
        }
    }

    /// After a decision that may have changed the PDF, replace only that file's snapshot. The original selection
    /// still determines which pairs the dialog offers. Edits for the other files are left alone.
    func refresh(fileID: String, keepKindsIfUnchanged: Bool = false) async {
        guard let index = files.firstIndex(where: { $0.id == fileID }) else { return }
        let old = files[index]
        let (file, choices) = await Self.readFile(old.url, selectedPairs: selectedPairs[old.url],
                                                 scanDetector: old.scanDetector)
        if keepKindsIfUnchanged, file.eligibility == old.eligibility { return }
        files[index] = file
        let pageIndex = pages.firstIndex { $0.fileID == fileID } ?? pages.endIndex
        let count = pages.dropFirst(pageIndex).prefix { $0.fileID == fileID }.count
        pages.replaceSubrange(pageIndex..<(pageIndex + count), with: choices)
    }

    /// PDFKit objects and the original bytes stay in this worker. Only value snapshots cross to the UI.
    @concurrent
    private static func readFile(_ url: URL, selectedPairs: [Int]?, scanDetector: NewspaperDetector) async
        -> (FileEntry, [ReOCRPageChoice]) {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let eligibility = ReOCRPairs.validate(data)
        let file = FileEntry(id: url.path, url: url, eligibility: eligibility, scanDetector: scanDetector)
        let wanted = selectedPairs.map(Set.init)
        let found = (try? eligibility.get()) ?? []
        var choices = found.filter { wanted?.contains($0.imageIndex / 2) ?? true }.map { pair in
            ReOCRPageChoice(fileID: file.id, pairIndex: pair.textIndex, kind: pair.header.kind,
                           origin: pair.header.kind == nil ? nil : .header, confidence: nil)
        }
        // A headerless page gets an on-device suggestion from its image.
        guard !Task.isCancelled, choices.contains(where: { $0.origin == nil }) else { return (file, choices) }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImproveOCR-kinds-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { return (file, choices) }
        defer { try? FileManager.default.removeItem(at: scratch) }
        for i in choices.indices where choices[i].origin == nil {
            guard !Task.isCancelled else { break }
            let image = scratch.appendingPathComponent("\(i).jpg")
            defer { try? FileManager.default.removeItem(at: image) }
            guard ReOCRJob.writeImageInput(data, pageIndex: choices[i].pairIndex - 1, to: image),
                  let cg = PageKindClassifier.loadImage(image) else { continue }
            guard let call = await PageKindClassifier.classify(cg), let kind = call.headerKind else { continue }
            choices[i].kind = kind
            choices[i].origin = .classifier
            choices[i].confidence = call.confidence
        }
        return (file, choices)
    }

    func setKind(_ kind: OCRPageKind?, file: String, pairIndex: Int) {
        guard let i = pages.firstIndex(where: { $0.fileID == file && $0.pairIndex == pairIndex }) else { return }
        pages[i].kind = kind
        pages[i].origin = kind == nil ? nil : .person
        pages[i].confidence = nil
    }

    /// The pages by Kind, each settled group with its ranking for exactly its pages.
    var groups: [Group] {
        ReOCRGrouping.groups(pages).map { g in
            Group(kind: g.kind, pages: g.pages, ranking: g.kind.map { ranking(for: $0, pages: g.pages.count) })
        }
    }

    private func ranking(for kind: OCRPageKind, pages count: Int) -> ReOCRRanking {
        let current = pages.first { $0.settledKind == kind }.flatMap { page in
            files.first { $0.id == page.fileID }?.pair(at: page.pairIndex)?.header.provenance
        }
        return ReOCRRanking.rank(kind: kind, pages: count, table: table, pairs: pairs, resources: resources,
                                 staysOnMac: staysOnMac, noTraining: noTraining, current: current)
    }

    // MARK: Choice and estimate

    func choose(_ rowID: String, for kind: OCRPageKind) { chosen[kind] = rowID }

    /// The chosen row for a settled group: the person's, else the ranking's suggestion.
    func chosenRow(_ group: Group) -> ReOCRRanking.Row? {
        guard let kind = group.kind, let ranking = group.ranking else { return nil }
        let id = chosen[kind] ?? ranking.suggestedID
        return ranking.rows.first { $0.id == id }
    }

    /// The selection's cost at the chosen rows' list prices, and how many pages have no known price (shown as
    /// unknown, never as $0).
    var estimate: (usd: Double, unpricedPages: Int) {
        var usd = 0.0, unpriced = 0
        for g in groups {
            guard let row = chosenRow(g), let cost = row.estimateUSD else { unpriced += g.pages.count; continue }
            usd += cost
        }
        return (usd, unpriced)
    }

    /// Why Run is not offered yet, or nil when it is: every page needs a Kind, every group a ready chosen row.
    var runBlocker: String? {
        if pages.isEmpty { return "no file here can be improved in place" }
        for g in groups {
            guard g.kind != nil else { return "choose a Kind for \(g.pages.count) page\(g.pages.count == 1 ? "" : "s")" }
            guard let row = chosenRow(g) else { return "no reader can read \(g.kind!.displayName) pages here" }
            if case .needsSetup(let why) = row.readiness { return "\(row.name): \(why)" }
        }
        return nil
    }

    // MARK: Run

    struct FileRun: Sendable {
        let fileID: String
        let outcome: Result<ReOCRJob.Review, ReOCRJob.Failure>
        let error: String?
    }

    /// Reads every eligible file through `job`, each page by its group's chosen reader (`readerFor` turns a row into
    /// one: `ReOCRJob.reader(for:apiKey:)` in the app, a fake in a test). Only an explicit Run calls this.
    func run(job: ReOCRJob, root: ReOCRJob.Root, model: LLMModel,
             readerFor: (ReOCRRanking.Row) -> ReOCRJob.Reader?) async -> [FileRun] {
        guard runBlocker == nil else { return [] }
        var readers: [OCRPageKind: ReOCRJob.Reader] = [:]
        var models: [OCRPageKind: LLMModel] = [:]
        for g in groups {
            guard let kind = g.kind, let row = chosenRow(g), let reader = readerFor(row) else { return [] }
            readers[kind] = reader
            models[kind] = row.provider.models.first { $0.id == row.modelID }
        }
        let byKind = readers
        let routed: ReOCRJob.Reader = { image, pair, kind in
            guard let kind, let reader = byKind[kind] else {
                return OCRResult(text: nil, classification: nil, errorMessage: "no reader was chosen for this page's Kind",
                                 errorCode: "no-reader")
            }
            return await reader(image, pair, kind)
        }
        var out: [FileRun] = []
        for file in files {
            if Task.isCancelled { break }   // the dialog closed: read and pay for nothing more
            let mine = pages.filter { $0.fileID == file.id }
            guard !mine.isEmpty else { continue }
            var kinds: [Int: OCRPageKind] = [:], pageModels: [Int: LLMModel] = [:]
            for p in mine {
                guard let k = p.settledKind else { continue }
                kinds[p.pairIndex] = k
                pageModels[p.pairIndex] = models[k]
            }
            do {
                // The file's collection's detector reaches the reader as the run's task-local (`ReOCRJob.reader`).
                let review = try await NewspaperPageReader.$scanDetector.withValue(file.scanDetector) {
                    try await job.start(file: file.url, root: root, textPages: Set(mine.map(\.pairIndex)),
                                        kinds: kinds, model: model, pageModels: pageModels, read: routed)
                }
                out.append(FileRun(fileID: file.id, outcome: .success(review), error: nil))
            } catch let f as ReOCRJob.Failure {
                out.append(FileRun(fileID: file.id, outcome: .failure(f), error: nil))
            } catch {
                out.append(FileRun(fileID: file.id, outcome: .failure(.noCandidate), error: "\(error)"))
            }
        }
        return out
    }
}
