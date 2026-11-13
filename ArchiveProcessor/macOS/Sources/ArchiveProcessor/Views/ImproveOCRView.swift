import AppKit
import ArchiveCore
import SwiftUI

// MARK: - Improve OCR: the dialog (W44.reocr-processor)

/// Every Improve OCR step that changes a file or its records (recover, accept, reject, restore, remove) runs on this one
/// serial queue, so none runs beside another: recovery never meets an accept in flight, and two clicks never race.
enum ImproveOCRWork {
    private static let queue = DispatchQueue(label: "com.archiveprocessor.improve-ocr.work", qos: .userInitiated)

    static func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { c.resume(with: Result { try body() }) } }
    }

    /// Recovery once per shared folder per launch, through the queue.
    @MainActor private static var recovered: Set<URL> = []
    @MainActor static func recoverOnce(support: URL, job: ReOCRJob, done: (@MainActor @Sendable ([ReOCRJob.Recovered]) -> Void)? = nil) {
        guard recovered.insert(support.standardizedFileURL).inserted else { return }
        Task {
            let result = (try? await perform { job.recover() }) ?? []
            done?(result)
        }
    }
}

/// The files the dialog was opened for.
struct ImproveOCRSelection: Identifiable {
    let id = UUID()
    let files: [URL]
    /// Pairs the Reader chose, by file (0-based); a file not here offers all its pairs.
    var pairs: [URL: [Int]] = [:]
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
    /// Run is offered once per opening: after it the file list is stale (an accepted file has a new reader); reopening
    /// the dialog reads the files again.
    @Published private(set) var hasRun = false
    @Published private(set) var reviews: [String: ReOCRJob.Review] = [:]
    @Published private(set) var messages: [String: String] = [:]
    @Published private(set) var recoveryNote: String?
    /// Files whose Accept or Reject is under way: both buttons are off until it finishes.
    @Published private(set) var deciding: Set<String> = []
    private var runTask: Task<Void, Never>?

    let model: ReOCRDialogModel?
    let loadProblem: String?
    private let connection: ReOCRSupportConnection

    /// `<Processor Application Support>/ImproveOCR`, where kept versions and journals live.
    static var privateFolder: URL {
        #if DEBUG
        // The UI suite's launches keep their versions beside their scratch shared folder, never in the real one.
        if let test = ProcessorUITestConfiguration.improveOCRSupport {
            return test.folder.deletingLastPathComponent()
                .appendingPathComponent("archive-processor-uitest-private-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.archiveprocessor.app", isDirectory: true)
            .appendingPathComponent("ImproveOCR", isDirectory: true)
    }

    /// The Processor's saved support connection (in the UI suite, a scratch folder in its own defaults suite).
    static func connection() -> ReOCRSupportConnection {
        #if DEBUG
        if let test = ProcessorUITestConfiguration.improveOCRSupport {
            let conn = ReOCRSupportConnection(defaults: test.defaults)
            _ = try? conn.connect(test.folder)   // this launch's own scratch folder, never an earlier run's
            return conn
        }
        #endif
        return ReOCRSupportConnection(defaults: .standard)
    }

    init(files: [URL], pairs selectedPairs: [URL: [Int]] = [:]) {
        let conn = Self.connection()
        connection = conn
        support = Result { try conn.resolve() }.mapError { ($0 as? ReOCRSupportConnection.Problem) ?? .unavailable("\($0)") }
        guard let table = SettingsRouteTable.bundled else {
            model = nil
            loadProblem = "the reading rule table is missing from this build"
            return
        }
        var resources = SettingsResources(macMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824)
        resources.keys = Set(LLMProvider.allCases.filter { $0 != .appleVision && KeychainHelper.load(account: $0.rawValue) != nil }
            .map { $0.rawValue.lowercased() })
        model = ReOCRDialogModel(files: files, selectedPairs: selectedPairs, table: table, pairs: OCRPairMatrix.bundled,
                                 resources: resources, staysOnMac: false)
        loadProblem = nil
        root = Self.findRoot(for: files)
        if root == nil { rootProblem = "these files are not inside one archive folder with a suite root marker" }
        // Pages whose header names no Kind get the classifier's provisional call.
        if let model {
            Task { [weak self] in
                await model.classifyUnknownPages()
                self?.revision += 1
            }
        }
        if case .success(let s) = support { recover(s.url) }
    }

    private func job(_ support: URL) -> ReOCRJob {
        let base = Self.privateFolder
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ReOCRJob(writer: ReOCRFileWriter(versionsRoot: base.appendingPathComponent("Versions", isDirectory: true)),
                        scratch: FileManager.default.temporaryDirectory.appendingPathComponent("ImproveOCR-\(UUID().uuidString)"),
                        support: support)
    }

    /// Settles anything a crash left before new work, once per launch and shared folder, on the serial work queue.
    private func recover(_ support: URL) {
        ImproveOCRWork.recoverOnce(support: support, job: job(support)) { [weak self] done in
            let open = done.filter {
                if case .conflict = $0.writer { return true }
                return $0.flag?.isFailure == true || $0.receiptProblem != nil
            }
            if !open.isEmpty { self?.recoveryNote = "\(open.count) earlier Improve OCR change\(open.count == 1 ? "" : "s") need a look." }
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
        guard runBlocker == nil, !hasRun, let model, let root, case .success(let s) = support else { return }
        running = true
        hasRun = true
        let job = job(s.url)
        var readerFor: (ReOCRRanking.Row) -> ReOCRJob.Reader? = { row in
            ReOCRJob.reader(for: row, apiKey: row.provider == .appleVision ? "" : (KeychainHelper.load(account: row.provider.rawValue) ?? ""))
        }
        #if DEBUG
        if ProcessorUITestConfiguration.improveOCRFakeReader {
            readerFor = { _ in { _, _, _ in OCRResult(text: "A TYPED LETTER OF 1952", classification: nil, errorMessage: nil, errorCode: nil) } }
        }
        #endif
        let chooseReader = readerFor
        runTask = Task {
            let runs = await model.run(job: job, root: root, model: LLMModel.appleVisionModels[0], readerFor: chooseReader)
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
            runTask = nil
            revision += 1
        }
    }

    /// Stops a run when the dialog closes: no further page is read or paid for. A file already read stays "not
    /// decided" in the history, its original untouched.
    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    func accept(_ fileID: String) {
        guard let review = reviews[fileID], !deciding.contains(fileID), case .success(let s) = support else { return }
        deciding.insert(fileID)
        let job = job(s.url)
        Task {
            var text: String
            do {
                let done = try await ImproveOCRWork.perform { try job.accept(review) }
                switch done.flag {
                case .cleared: text = "Accepted. The OCR Poor flag was cleared."
                case .notFlagged: text = "Accepted."
                case .changedSinceReview(let why): text = "Accepted. The flag was left: \(why)."
                case .failed(let why): text = "Text accepted; the flag still needs clearing (\(why))."
                }
                if done.receiptProblem != nil || done.recordProblem != nil {
                    text += " Its record for the Reader is not finished yet; it will be completed at the next launch."
                }
            } catch { text = "Not accepted: \(error)" }
            messages[fileID] = text
            reviews[fileID] = nil
            deciding.remove(fileID)
            revision += 1
        }
    }

    func reject(_ fileID: String) {
        guard let review = reviews[fileID], !deciding.contains(fileID), case .success(let s) = support else { return }
        deciding.insert(fileID)
        let job = job(s.url)
        Task {
            do { try await ImproveOCRWork.perform { try job.reject(review) }; messages[fileID] = "Rejected. The file is unchanged." }
            catch { messages[fileID] = "\(error)" }
            reviews[fileID] = nil
            deciding.remove(fileID)
            revision += 1
        }
    }
}

/// The Files tab's Improve OCR entry points, kept out of its long body: the menu command (for its PDFs), a hand-off
/// link from the Reader (`ImproveOCRHandoff`; a message instead when it cannot open), and the sheet.
struct ImproveOCRHooks: ViewModifier {
    @Binding var selection: ImproveOCRSelection?
    @Binding var message: String?
    let files: [URL]
    let canOpen: Bool
    @State private var showsHistory = false

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .improveOCRRequested)) { _ in
                guard canOpen, !SheetGuard.sheetIsUp else { return }
                let pdfs = files.filter { $0.pathExtension.lowercased() == "pdf" }
                if !pdfs.isEmpty { selection = ImproveOCRSelection(files: pdfs) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .improveOCRHandoff)) { _ in takePending() }
            .onAppear { Self.recoverOnce(); takePending() }
            .sheet(item: $selection) { ImproveOCRView(files: $0.files, pairs: $0.pairs) }
            .onReceive(NotificationCenter.default.publisher(for: .improveOCRHistoryRequested)) { _ in
                guard canOpen, selection == nil, !SheetGuard.sheetIsUp else { return }
                showsHistory = true
            }
            .sheet(isPresented: $showsHistory) { ImproveOCRHistoryView() }
            .onReceive(NotificationCenter.default.publisher(for: .improveOCRFlaggedRequested)) { _ in
                guard canOpen, selection == nil, !SheetGuard.sheetIsUp else { return }
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.prompt = "Find Flagged Files"
                panel.message = "Choose a folder: Improve OCR opens for the PDFs in it flagged OCR Poor."
                guard panel.runModal() == .OK, let folder = panel.url else { return }
                Task.detached {
                    let found = ReOCRFlaggedFinder.find(in: folder)
                    await MainActor.run {
                        if found.files.isEmpty {
                            message = "No PDF in \(folder.lastPathComponent) is flagged OCR Poor (\(found.scanned) checked)."
                        } else {
                            selection = ImproveOCRSelection(files: found.files)
                            if found.truncated || found.unreadableFolders > 0 {
                                message = (found.truncated ? "Showing the first \(found.files.count) flagged files. " : "")
                                    + (found.unreadableFolders > 0 ? "\(found.unreadableFolders) folder(s) could not be read." : "")
                            }
                        }
                    }
                }
            }
            .alert("Improve OCR", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: {
                Text(message ?? "")
            }
    }
}

extension ImproveOCRHooks {
    /// A waiting link, taken only when the dialog can show (the same guards as the menu command); otherwise the person
    /// is told, and the request is not recorded, so sending it again works.
    func takePending() {
        guard let url = ImproveOCRHandoff.pending else { return }
        guard canOpen, selection == nil, !SheetGuard.sheetIsUp else {
            ImproveOCRHandoff.pending = nil
            message = "The Processor is busy. The request was not used: send it again from the Reader when the current run or dialog is finished."
            return
        }
        ImproveOCRHandoff.pending = nil
        switch ImproveOCRHandoff.handle(url, connection: ImproveOCRController.connection()) {
        case .open(let found, let pairs): selection = ImproveOCRSelection(files: found, pairs: pairs)
        case .message(let text): message = text
        }
    }

    /// Once per launch, before any new work: settle what a crash left (receipts and flags included), on the work queue.
    static func recoverOnce() {
        guard case .success(let s) = Result(catching: { try ImproveOCRController.connection().resolve() }) else { return }
        let base = ImproveOCRController.privateFolder
        let job = ReOCRJob(writer: ReOCRFileWriter(versionsRoot: base.appendingPathComponent("Versions", isDirectory: true)),
                           scratch: FileManager.default.temporaryDirectory.appendingPathComponent("ImproveOCR-\(UUID().uuidString)"),
                           support: s.url)
        ImproveOCRWork.recoverOnce(support: s.url, job: job)
    }
}

/// Processing ▸ Improve OCR History…: every change Improve OCR kept a copy for, newest first, with Restore for an accepted
/// change and Remove (after a confirmation) for a decided one. Restore and removal run off the main thread.
struct ImproveOCRHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ReOCRHistory.Entry] = []
    @State private var note: String?
    @State private var confirmRemove: ReOCRHistory.Entry?
    @State private var busy = false

    private var history: ReOCRHistory {
        ReOCRHistory(writer: ReOCRFileWriter(versionsRoot: ImproveOCRController.privateFolder.appendingPathComponent("Versions", isDirectory: true)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Improve OCR History").font(.title2.bold())
            Text("Kept copies stay until you remove them. \(ByteCountFormatter.string(fromByteCount: entries.reduce(0) { $0 + $1.bytes }, countStyle: .file)) kept.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("ap.reocr.history.total")
            if entries.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary).accessibilityIdentifier("ap.reocr.history.empty")
            }
            List(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.file.lastPathComponent).bold()
                        Text("\(Self.describe(entry.state)) · \(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if entry.canRestore {
                        Button("Restore") { restore(entry) }.disabled(busy).accessibilityIdentifier("ap.reocr.history.restore")
                    }
                    Button("Remove\u{2026}") { confirmRemove = entry }
                        .disabled(!entry.canRemove || busy)
                        .accessibilityIdentifier("ap.reocr.history.remove")
                }
            }
            .frame(minHeight: 220)
            if let note { Text(note).font(.callout).accessibilityIdentifier("ap.reocr.history.note") }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 380)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ap.reocr.history")
        .onAppear { entries = history.entries() }
        .confirmationDialog("Remove the kept copy?", isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { entry in
            Button("Remove", role: .destructive) { remove(entry) }
        } message: { entry in
            Text(entry.state == .accepted
                 ? "This deletes the only kept copy of \(entry.file.lastPathComponent) as it was before the change; the change can then no longer be undone."
                 : "After this, this change can no longer be undone from here.")
        }
    }

    static func describe(_ state: ReOCRHistory.Entry.State) -> String {
        switch state {
        case .accepted: "Accepted"
        case .restoredEarlier: "Old text put back"
        case .undone: "Accepted, then undone"
        case .rejected: "Rejected"
        case .undecided: "Not decided"
        case .interrupted: "Stopped during publication"
        case .unreadable: "Record unreadable"
        }
    }

    private func restore(_ entry: ReOCRHistory.Entry) {
        guard case .success(let s) = Result(catching: { try ImproveOCRController.connection().resolve() }) else {
            note = "Connect the shared folder first (Improve OCR\u{2026})."
            return
        }
        let job = ReOCRJob(writer: history.writer, scratch: FileManager.default.temporaryDirectory.appendingPathComponent("ImproveOCR-\(UUID().uuidString)"),
                           support: s.url)
        busy = true
        Task {
            let text: String
            do {
                let r = try await ImproveOCRWork.perform { try job.restore(entry.id) }
                switch r.flag {
                case .reflagged: text = "The old text is back, and so is the OCR Poor flag."
                case .notNeeded: text = "The old text is back."
                case .changedSinceClear(let why): text = "The old text is back. The flag was left: \(why)."
                case .failed(let why): text = "The old text is back; the flag could not be put back (\(why))."
                }
            } catch { text = "\(error)" }
            note = text
            entries = ReOCRHistory(writer: job.writer).entries()
            busy = false
        }
    }

    private func remove(_ entry: ReOCRHistory.Entry) {
        let h = history
        busy = true
        Task {
            do { try await ImproveOCRWork.perform { try h.remove(entry.id) }; note = "Removed." } catch { note = "\(error)" }
            entries = h.entries()
            busy = false
        }
    }
}

struct ImproveOCRView: View {
    @StateObject private var controller: ImproveOCRController
    @Environment(\.dismiss) private var dismiss

    init(files: [URL], pairs: [URL: [Int]] = [:]) {
        _controller = StateObject(wrappedValue: ImproveOCRController(files: files, pairs: pairs))
    }

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
        .onDisappear { controller.cancel() }
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
                        if let p = controller.model?.provisional(file: file.id) {
                            Text(p.confidence >= PageKindRouting.minimumConfidence
                                 ? "suggested: \(p.kind.displayName), \(Int(p.confidence * 100))%"
                                 : "unsure (\(p.kind.displayName)?, \(Int(p.confidence * 100))%): choose")
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
                                .disabled(controller.deciding.contains(fileID))
                                .accessibilityIdentifier("ap.reocr.reject")
                            Button("Accept") { controller.accept(fileID) }
                                .keyboardShortcut(.defaultAction)
                                .disabled(review.candidate == nil || controller.deciding.contains(fileID))
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
                .disabled(controller.runBlocker != nil || controller.running || controller.hasRun)
                .accessibilityIdentifier("ap.reocr.run")
        }
    }
}

private extension Result where Failure == ReOCRPairs.Refusal {
    var failureDescription: String? { if case .failure(let f) = self { return f.description }; return nil }
}
