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
        /// The reader its first text page names, for display only.
        let currentReader: PDFReaderProvenance?
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

    /// `selectedPairs` keeps, for a file the Reader named pairs for, only those pairs (0-based); a pair past the end of
    /// the file is ignored.
    init(files urls: [URL], selectedPairs: [URL: [Int]] = [:], table: SettingsRouteTable, pairs: OCRPairMatrix?,
         resources: SettingsResources, staysOnMac: Bool) {
        self.table = table
        self.pairs = pairs
        self.resources = resources
        self.staysOnMac = staysOnMac
        for url in urls {
            let data = (try? Data(contentsOf: url)) ?? Data()
            let eligibility = ReOCRPairs.validate(data)
            let found = (try? eligibility.get()) ?? []
            files.append(FileEntry(id: url.path, url: url, eligibility: eligibility, currentReader: found.first?.header.provenance))
            let wanted = selectedPairs[url].map { Set($0.map { $0 * 2 + 1 }) }
            for pair in found where wanted?.contains(pair.textIndex) ?? true {
                pages.append(ReOCRPageChoice(fileID: url.path, pairIndex: pair.textIndex, kind: pair.header.kind,
                                             origin: pair.header.kind == nil ? nil : .header, confidence: nil))
            }
        }
    }

    // MARK: Kinds

    /// Asks the page-kind classifier about every page with no Kind from its header or the person (plan §4): its answer
    /// is provisional, shown as such, and below the routing threshold (`PageKindRouting.minimumConfidence`) it is no
    /// Kind at all, so the page still needs the person's choice. The image page is read, never the old text.
    func classifyUnknownPages() async {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("ImproveOCR-kinds-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        for i in pages.indices where pages[i].origin == nil {
            let page = pages[i]
            guard let file = files.first(where: { $0.id == page.fileID }), let data = try? Data(contentsOf: file.url) else { continue }
            let image = scratch.appendingPathComponent("\(i).jpg")
            guard ReOCRJob.writeImageInput(data, pageIndex: page.pairIndex - 1, to: image),
                  let cg = PageKindClassifier.loadImage(image) else { continue }
            let call = await PageKindClassifier.classify(cg)
            try? FileManager.default.removeItem(at: image)
            guard let call, pages[i].origin == nil else { continue }
            let kind = call.kind.headerKind
            pages[i].kind = kind
            pages[i].origin = .classifier
            pages[i].confidence = call.confidence
        }
    }

    /// The classifier's provisional call for a file's first page, for display: its Kind and confidence.
    func provisional(file: String) -> (kind: OCRPageKind, confidence: Double)? {
        guard let p = pages.first(where: { $0.fileID == file }), p.origin == .classifier, let k = p.kind else { return nil }
        return (k, p.confidence ?? 0)
    }

    /// The person's Kind for one page (by its text page's index), or for every page of a file when `pairIndex` is nil.
    func setKind(_ kind: OCRPageKind?, file: String, pairIndex: Int? = nil) {
        for i in pages.indices where pages[i].fileID == file && (pairIndex == nil || pages[i].pairIndex == pairIndex) {
            pages[i].kind = kind
            pages[i].origin = kind == nil ? nil : .person
            pages[i].confidence = nil
        }
    }

    /// The pages by Kind, each settled group with its ranking for exactly its pages.
    var groups: [Group] {
        ReOCRGrouping.groups(pages).map { g in
            Group(kind: g.kind, pages: g.pages, ranking: g.kind.map { ranking(for: $0, pages: g.pages.count) })
        }
    }

    private func ranking(for kind: OCRPageKind, pages count: Int) -> ReOCRRanking {
        let current = pages.first { $0.settledKind == kind }.flatMap { p in files.first { $0.id == p.fileID }?.currentReader }
        return ReOCRRanking.rank(kind: kind, pages: count, table: table, pairs: pairs, resources: resources,
                                 staysOnMac: staysOnMac, current: current)
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
                let review = try await job.start(file: file.url, root: root, textPages: Set(mine.map(\.pairIndex)),
                                                 kinds: kinds, model: model, pageModels: pageModels, read: routed)
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
