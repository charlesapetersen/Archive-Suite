import SwiftUI

/// The file list's page kinds and readers (W41.app-page-kind). Classifies each dropped image file once, on this Mac,
/// one page at a time off the main actor, and keeps the user's per-page and per-batch choices. `plan` freezes them
/// into the `PageReaderPlan` the run reads.
@MainActor
final class PageKindStore: ObservableObject {
    /// Each classified page's kind by standardized path; a nil value means it was tried and could not be told.
    @Published private(set) var kinds: [String: PageKind?] = [:]
    /// A reader the user chose: the run's model (whichever it is at Start, so it follows a later model change), or one
    /// named model.
    enum Pick: Equatable {
        case run
        case model(PageKindRouting.Candidate)

        func resolve(_ runDefault: PageKindRouting.Candidate) -> PageKindRouting.Candidate {
            if case .model(let c) = self { return c }
            return runDefault
        }
    }

    /// The user's reader for one page; wins over the batch choice and the kind.
    @Published var overrides: [String: Pick] = [:]
    /// The user's reader for every page of the batch; nil = by kind.
    @Published var batchOverride: Pick?
    /// Pages still waiting to be classified.
    @Published private(set) var pending = 0
    /// Every built-in model the user has a key for, refreshed with the file list (one Keychain read per provider).
    @Published private(set) var available: Set<PageKindRouting.Candidate> = []

    /// Test seam: replaces the classifier (headless tests have no real page). nil in production.
    nonisolated(unsafe) static var classifyOverride: (@Sendable (URL) async -> PageKind?)?
    /// Test seam: replaces the Keychain for `available`. nil in production.
    nonisolated(unsafe) static var availableOverride: Set<PageKindRouting.Candidate>?

    private var worker: Task<Void, Never>?
    private var queue: [URL] = []

    /// Classify the image files among `urls` that have not been classified yet, and refresh `available`. PDFs are
    /// left out: their pages are drawn to images only during the run, so they keep the run's model.
    func update(_ urls: [URL]) {
        available = Self.availableOverride ?? PageKindRouting.keyedCandidates()
        let wanted = Set(urls.map(PageReaderPlan.key))
        overrides = overrides.filter { wanted.contains($0.key) }
        let fresh = urls.filter { !Self.isPDF($0) && kinds[PageReaderPlan.key($0)] == nil
            && !queue.contains($0) }
        queue.append(contentsOf: fresh)
        pending = queue.count
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, let url = self.queue.first {
                let kind = await Self.classify(url)
                self.queue.removeFirst()
                self.kinds[PageReaderPlan.key(url)] = .some(kind)
                self.pending = self.queue.count
            }
            self?.worker = nil
        }
    }

    nonisolated private static func classify(_ url: URL) async -> PageKind? {
        if let o = classifyOverride { return await o(url) }
        return await Task.detached(priority: .utility) {
            guard let image = PageKindClassifier.loadImage(url) else { return nil }
            return await PageKindClassifier.classify(image)
        }.value
    }

    static func isPDF(_ url: URL) -> Bool { url.pathExtension.lowercased() == "pdf" }

    func kind(for url: URL) -> PageKind?? { kinds[PageReaderPlan.key(url)] }

    /// The page's reader now, with the choices as they stand.
    func choice(for url: URL, guidance: OCRPageGuidance?, runDefault: PageKindRouting.Candidate) -> PageKindRouting.Choice? {
        guard let told = kind(for: url) else { return nil }   // not classified yet
        return PageKindRouting.choose(kind: told, guidance: guidance, available: available, runDefault: runDefault,
                                      override: (overrides[PageReaderPlan.key(url)] ?? batchOverride)?.resolve(runDefault))
    }

    /// The run's plan: every classified image file among `urls`. A page still waiting is left out (the run's model).
    func plan(_ urls: [URL], guidance: OCRPageGuidance?, runDefault: PageKindRouting.Candidate) -> PageReaderPlan {
        var plan = PageReaderPlan()
        for url in urls {
            guard let told = kind(for: url), let c = choice(for: url, guidance: guidance, runDefault: runDefault)
            else { continue }
            plan.pages[PageReaderPlan.key(url)] = .init(kind: told, choice: c)
        }
        return plan
    }

    /// Readers to offer in the menus, by provider then name.
    var menuCandidates: [(PageKindRouting.Candidate, LLMModel)] {
        available.compactMap { c in PageKindRouting.model(c).map { (c, $0) } }
            .sorted { ($0.1.provider.rawValue, $0.1.displayName) < ($1.1.provider.rawValue, $1.1.displayName) }
    }
}

extension CostEstimate {
    /// The same estimate with `delta` added to its standard-rate OCR cost (the per-page readers, W41.app-page-kind).
    /// The batch rate is left alone: a paid batch reads every page with the run's model.
    func addingOCR(_ delta: Double) -> CostEstimate {
        CostEstimate(ocrCost: max(0, ocrCost + delta), classificationCost: classificationCost, taggingCost: taggingCost,
                     collectionCost: collectionCost, rotationCost: rotationCost, batchOcrCost: batchOcrCost,
                     fileCount: fileCount, model: model)
    }
}

/// One file row's kind and reader, with a menu to choose another reader for that page.
struct PageKindRowLine: View {
    @ObservedObject var store: PageKindStore
    let url: URL
    let guidance: OCRPageGuidance?
    let runDefault: PageKindRouting.Candidate
    let runModel: LLMModel

    /// The line's text and whether it names another model than the run's; nil until the page is told.
    var label: (text: String, routed: Bool)? {
        guard let told = store.kind(for: url), let c = store.choice(for: url, guidance: guidance, runDefault: runDefault)
        else { return nil }
        let name = PageKindRouting.model(.init(provider: c.provider, modelID: c.modelID))?.displayName ?? runModel.displayName
        let routed = (c.reason == .kind || c.reason == .override) && c != runDefaultChoice(c.reason)
        return (PageKindRouting.summary(kind: told, choice: c, modelName: name), routed)
    }

    private func runDefaultChoice(_ r: PageKindRouting.Reason) -> PageKindRouting.Choice {
        .init(provider: runDefault.provider, modelID: runDefault.modelID, reason: r)
    }

    /// The menu's label: plain text, so the render guard can draw it (a Menu itself draws as a placeholder offscreen).
    struct Label: View {
        let text: String
        let routed: Bool
        var body: some View {
            Text(text).font(.caption2).foregroundStyle(routed ? Color.accentColor : .secondary)
        }
    }

    var body: some View {
        if let label {
            Menu {
                Button("By its kind") { store.overrides[PageReaderPlan.key(url)] = nil }
                Button("The run's model (now \(runModel.displayName))") { store.overrides[PageReaderPlan.key(url)] = .run }
                Divider()
                ForEach(store.menuCandidates, id: \.0) { cand, m in
                    Button("\(m.provider.rawValue) · \(m.displayName)") { store.overrides[PageReaderPlan.key(url)] = .model(cand) }
                }
            } label: {
                Label(text: label.text, routed: label.routed)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("ap.ocr.pageKind")
        } else if !PageKindStore.isPDF(url) {
            Text("Telling the page's kind…").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// The batch's reader choice and what the per-page readers do to the estimate, for the cost pane.
struct PageKindBatchControl: View {
    @ObservedObject var store: PageKindStore
    let plan: PageReaderPlan
    let runDefault: PageKindRouting.Candidate
    let runModel: LLMModel

    var title: String {
        "Page readers: " + (store.batchOverride.flatMap { PageKindRouting.model($0.resolve(runDefault))?.displayName }
            .map { "\($0) for every page" } ?? "by each page's kind")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Menu {
                Button("By each page's kind") { store.batchOverride = nil }
                Button("The run's model for every page (now \(runModel.displayName))") { store.batchOverride = .run }
                Divider()
                ForEach(store.menuCandidates, id: \.0) { cand, m in
                    Button("\(m.provider.rawValue) · \(m.displayName) for every page") { store.batchOverride = .model(cand) }
                }
            } label: {
                Text(title)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("ap.ocr.pageKindBatch")
            let routed = plan.routedCounts(runModel: runModel)
            if !routed.isEmpty {
                Text("Read by another model, in the totals: "
                     + routed.map { "\($0.1) by \($0.0.displayName)" }.joined(separator: ", ") + ".")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.pending > 0 {
                Text("Telling \(store.pending) \(store.pending == 1 ? "page's" : "pages'") kind; a page not told by Start keeps the run's model.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
