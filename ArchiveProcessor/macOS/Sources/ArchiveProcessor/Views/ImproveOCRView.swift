import AppKit
import ArchiveCore
import SwiftUI

// MARK: - Improve OCR: the dialog (W44.reocr-processor)

/// The files the dialog was opened for.
struct ImproveOCRSelection: Identifiable {
    let id = UUID()
    let files: [URL]
}

/// The dialog's controller: the headless `ReOCRDialogModel` plus what only the app has (the support connection, the
/// archive root, the Keychain, the Processor's own Versions folder) and the runs in progress.
@MainActor
final class ImproveOCRController: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var support: Result<ReOCRSupportConnection.Connected, ReOCRSupportConnection.Problem>
    @Published private(set) var root: ReOCRJob.Root?
    @Published private(set) var rootProblem: String?
    @Published private(set) var running = false
    @Published private(set) var reviews: [String: ReOCRJob.Review] = [:]
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var recoveryNote: String?

    let model: ReOCRDialogModel?
    let loadProblem: String?
    private let connection = ReOCRSupportConnection(defaults: .standard)

    /// `<Processor Application Support>/ImproveOCR`, where kept versions and journals live.
    static var privateFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.archiveprocessor.app", isDirectory: true)
            .appendingPathComponent("ImproveOCR", isDirectory: true)
    }

    init(files: [URL]) {
        let conn = ReOCRSupportConnection(defaults: .standard)
        support = Result { try conn.resolve() }.mapError { ($0 as? ReOCRSupportConnection.Problem) ?? .unavailable("\($0)") }
        guard let table = SettingsRouteTable.bundled else {
            model = nil
            loadProblem = "the reading rule table is missing from this build"
            return
        }
        var resources = SettingsResources(macMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        resources.keys = Set(LLMProvider.allCases.filter { $0 != .appleVision && KeychainHelper.load(account: $0.rawValue) != nil }
            .map { $0.rawValue.lowercased() })
        model = ReOCRDialogModel(files: files, table: table, pairs: OCRPairMatrix.bundled, resources: resources, staysOnMac: false)
        loadProblem = nil
        root = Self.findRoot(for: files)
        if root == nil { rootProblem = "these files are not inside one archive folder with a suite root marker" }
        if case .success(let s) = support { recover(s.url) }
    }

    private func job(_ support: URL) -> ReOCRJob {
        let base = Self.privateFolder
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ReOCRJob(writer: ReOCRFileWriter(versionsRoot: base.appendingPathComponent("Versions", isDirectory: true)),
                        scratch: FileManager.default.temporaryDirectory.appendingPathComponent("ImproveOCR-\(UUID().uuidString)"),
                        support: support)
    }

    /// Settles anything a crash left before new work (off the main thread: it can wait on another app's flag lock).
    private func recover(_ support: URL) {
        let job = job(support)
        Task.detached {
            let done = job.recover()
            let open = done.filter { if case .conflict = $0.writer { return true }; return $0.flag?.isFailure == true }
            if !open.isEmpty {
                await MainActor.run { self.recoveryNote = "\(open.count) earlier Improve OCR change\(open.count == 1 ? "" : "s") need a look." }
            }
        }
    }

    /// The archive root all `files` are inside: the nearest folder above the first with a root marker.
    static func findRoot(for files: [URL]) -> ReOCRJob.Root? {
        guard var dir = files.first?.deletingLastPathComponent().standardizedFileURL else { return nil }
        while dir.pathComponents.count > 1 {
            if let marker = try? RootMarker.read(at: dir) {
                let prefix = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
                guard files.allSatisfy({ $0.standardizedFileURL.path.hasPrefix(prefix) }) else { return nil }
                return ReOCRJob.Root(guid: marker.guid, url: dir)
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    func connectSupport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Connect"
        panel.message = "Choose the Improve OCR shared folder (the Archive Reader connects the same one)."
        let suggested = ImproveOCRSupportIdentity.suggestedLocation
        try? FileManager.default.createDirectory(at: suggested, withIntermediateDirectories: true)
        panel.directoryURL = suggested
        guard panel.runModal() == .OK, let url = panel.url else { return }
        support = Result { try connection.connect(url) }.mapError { ($0 as? ReOCRSupportConnection.Problem) ?? .unavailable("\($0)") }
        if case .success(let s) = support { recover(s.url) }
    }

    func setKind(_ kind: OCRPageKind?, file: String) {
        model?.setKind(kind, file: file)
        revision += 1
    }

    func choose(_ row: String, for kind: OCRPageKind) {
        model?.choose(row, for: kind)
        revision += 1
    }

    var runBlocker: String? {
        if let loadProblem { return loadProblem }
        if case .failure(let p) = support { return p.description }
        if root == nil { return rootProblem }
        return model?.runBlocker
    }

    func run() {
        guard runBlocker == nil, let model, let root, case .success(let s) = support else { return }
        running = true
        let job = job(s.url)
        Task {
            let runs = await model.run(job: job, root: root, model: LLMModel.appleVisionModels[0], readerFor: { row in
                ReOCRJob.reader(for: row, apiKey: row.provider == .appleVision ? "" : (KeychainHelper.load(account: row.provider.rawValue) ?? ""))
            })
            for r in runs {
                switch r.outcome {
                case .success(let review):
                    reviews[r.fileID] = review
                    messages[r.fileID] = review.candidate == nil
                        ? "Not every page was read: " + review.results.compactMap { if case .failure(let f) = $0.outcome { return f.description }; return nil }.joined(separator: "; ")
                        : "Read. Compare and accept or reject."
                case .failure(let f): messages[r.fileID] = r.error ?? f.description
                }
            }
            running = false
            revision += 1
        }
    }

    func accept(_ fileID: String) {
        guard let review = reviews[fileID], case .success(let s) = support else { return }
        let job = job(s.url)
        Task.detached {
            let text: String
            do {
                let done = try job.accept(review)
                switch done.flag {
                case .cleared: text = "Accepted. The OCR Poor flag was cleared."
                case .notFlagged: text = "Accepted."
                case .changedSinceReview(let why): text = "Accepted. The flag was left: \(why)."
                case .failed(let why): text = "Text accepted; the flag still needs clearing (\(why))."
                }
            } catch { text = "Not accepted: \(error)" }
            await MainActor.run {
                self.messages[fileID] = text
                self.reviews[fileID] = nil
                self.revision += 1
            }
        }
    }

    func reject(_ fileID: String) {
        guard let review = reviews[fileID], case .success(let s) = support else { return }
        do { try job(s.url).reject(review); messages[fileID] = "Rejected. The file is unchanged." }
        catch { messages[fileID] = "\(error)" }
        reviews[fileID] = nil
        revision += 1
    }
}

struct ImproveOCRView: View {
    @StateObject private var controller: ImproveOCRController
    @Environment(\.dismiss) private var dismiss

    init(files: [URL]) { _controller = StateObject(wrappedValue: ImproveOCRController(files: files)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Improve OCR").font(.title2.bold())
            connectionRow
            if let note = controller.recoveryNote { Text(note).foregroundStyle(.orange) }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    filesSection
                    groupsSection
                    reviewSection
                }
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 560)
        // A container, so the identifier names the dialog without overriding its controls' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.reocr.dialog")
    }

    private var connectionRow: some View {
        HStack {
            switch controller.support {
            case .success(let s): Label("Shared folder: \(s.url.path)", systemImage: "checkmark.circle").lineLimit(1)
            case .failure(let p): Label(p.description, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            Button("Connect Shared Folder\u{2026}") { controller.connectSupport() }
                .accessibilityIdentifier("ap.reocr.connect")
        }
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Files").font(.headline)
            if let p = controller.rootProblem { Text(p).foregroundStyle(.orange) }
            ForEach(controller.model?.files ?? []) { file in
                HStack(alignment: .firstTextBaseline) {
                    Text(file.url.lastPathComponent).bold()
                    switch file.eligibility {
                    case .success(let pairs):
                        Text("\(pairs.count) page\(pairs.count == 1 ? "" : "s")").foregroundStyle(.secondary)
                        if let r = file.currentReader { Text("now read by \(r.provider) · \(r.model)").foregroundStyle(.secondary) }
                        Spacer()
                        Picker("Kind", selection: Binding(
                            get: { controller.model?.pages.first { $0.fileID == file.id }?.settledKind },
                            set: { controller.setKind($0, file: file.id) })) {
                            Text("Choose\u{2026}").tag(OCRPageKind?.none)
                            ForEach(OCRPageKind.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                        }
                        .frame(width: 220)
                        .accessibilityIdentifier("ap.reocr.kind.\(file.url.lastPathComponent)")
                    case .failure(let refusal):
                        Text(refusal.description).foregroundStyle(.secondary)
                    }
                }
                if let m = controller.messages[file.id] {
                    Text(m).font(.callout).accessibilityIdentifier("ap.reocr.message.\(file.url.lastPathComponent)")
                }
            }
        }
    }

    private var groupsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array((controller.model?.groups ?? []).enumerated()), id: \.offset) { _, group in
                if let kind = group.kind, let ranking = group.ranking {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(kind.displayName): \(group.pages.count) page\(group.pages.count == 1 ? "" : "s")").font(.headline)
                        ForEach(ranking.rows) { row in rowView(row, kind: kind, group: group) }
                        ForEach(ranking.institutional, id: \.id) { r in
                            Text("\(r.name): \(r.reason)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .id(controller.revision)
    }

    private func rowView(_ row: ReOCRRanking.Row, kind: OCRPageKind, group: ReOCRDialogModel.Group) -> some View {
        let chosen = controller.model?.chosenRow(group)?.id == row.id
        return Button { controller.choose(row.id, for: kind) } label: {
            HStack {
                Image(systemName: chosen ? "largecircle.fill.circle" : "circle")
                Text(row.name)
                if row.isCurrent { Text("current").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text(row.figure.map { String(format: "NES %.0f", $0) } ?? "not measured").foregroundStyle(.secondary)
                Text(row.usdPer1000.map { String(format: "$%.2f / 1,000", $0) } ?? "price unknown").foregroundStyle(.secondary)
                Text(row.estimateUSD.map { String(format: "$%.3f", $0) } ?? "unknown")
                if case .needsSetup(let why) = row.readiness { Text(why).font(.caption).foregroundStyle(.orange) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("ap.reocr.row.\(kind.rawValue).\(row.id)")
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(controller.reviews.keys.sorted()), id: \.self) { fileID in
                if let review = controller.reviews[fileID] {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(URL(fileURLWithPath: fileID).lastPathComponent).font(.headline)
                        ForEach(review.results, id: \.pair.textIndex) { r in
                            HStack(alignment: .top, spacing: 12) {
                                textColumn("Before", r.oldText)
                                textColumn("After", (try? r.outcome.get()) ?? ((r.outcome.failureDescription) ?? ""))
                            }
                        }
                        HStack {
                            Button("Reject") { controller.reject(fileID) }
                                .accessibilityIdentifier("ap.reocr.reject")
                            Button("Accept") { controller.accept(fileID) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(review.candidate == nil)
                                .accessibilityIdentifier("ap.reocr.accept")
                        }
                    }
                }
            }
        }
    }

    private func textColumn(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ScrollView { Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 160)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if let blocker = controller.runBlocker {
                Text(blocker).foregroundStyle(.secondary).accessibilityIdentifier("ap.reocr.blocker")
            } else if let e = controller.model?.estimate {
                Text(e.unpricedPages > 0 ? String(format: "About $%.3f, plus %d page(s) at an unknown price", e.usd, e.unpricedPages)
                                         : String(format: "About $%.3f", e.usd))
                    .accessibilityIdentifier("ap.reocr.estimate")
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(controller.running ? "Reading\u{2026}" : "Run") { controller.run() }
                .disabled(controller.runBlocker != nil || controller.running || !controller.reviews.isEmpty)
                .accessibilityIdentifier("ap.reocr.run")
        }
    }
}

private extension Result where Failure == ReOCRPairs.Refusal {
    var failureDescription: String? { if case .failure(let f) = self { return f.description }; return nil }
}
