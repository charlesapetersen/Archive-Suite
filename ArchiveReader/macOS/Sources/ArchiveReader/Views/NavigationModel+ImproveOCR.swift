import AppKit
import PDFKit
import ArchiveCore

// MARK: - Improve OCR in the navigation window (W44.reocr-reader)
//
// Flag as Poor OCR / Remove Poor OCR Flag, for the list's selection or the document window's file, and Improve OCR…,
// which hands the selection to Archive Processor's review dialog (`SPEC/improve-ocr.md`). Flagging writes the
// `OCR Poor` subject through the same `TagWriter` delta, ledger and undo as every other tag edit; the shared flag
// protocol rides inside `TagWriter` (`PoorOCRFlagGuard`). Neither action launches anything on its own but the
// Processor's dialog, which only shows what it would do.

extension NavigationModel {
    /// Every target already carries the flag, so the command removes it.
    func poorOCRWouldClear(paths: [String]? = nil) -> Bool {
        let targets = tagTargets(paths)
        return !targets.isEmpty && targets.allSatisfy(\.tags.hasPoorOCR)
    }

    func poorOCRCommandTitle(paths: [String]? = nil) -> String {
        poorOCRWouldClear(paths: paths) ? "Remove Poor OCR Flag" : ReaderCommand.togglePoorOCR.title
    }

    /// Flags the targets, or removes the flag when every one already carries it. A file that already has the value
    /// is still recorded, since the action is the person's verdict on it. Runs off the main thread: each file's flag
    /// record is synchronized to disk.
    func togglePoorOCR(paths: [String]? = nil) {
        let targets = tagTargets(paths)
        guard !targets.isEmpty else {
            statusMessage = paths == nil ? "Select the files to flag." : "This file is not in the archive's library, so it cannot be flagged here."
            announce(statusMessage)
            return
        }
        guard connectImproveOCRFolderIfNeeded() else { return }
        let flag = !targets.allSatisfy(\.tags.hasPoorOCR)
        Task { await setPoorOCR(flag, on: targets) }
    }

    /// The flag write itself, awaited by tests. Returns the verified results.
    @discardableResult
    func setPoorOCR(_ flag: Bool, on targets: [ArchiveFile]) async -> [TagWriteResult] {
        let reverified = reverifyCacheRows(targets)
        let files = reverified.files
        let delta = flag ? TagDelta(add: [DocumentTags.poorOCRTag]) : TagDelta(remove: [DocumentTags.poorOCRTag])
        let items = files.map { (url: $0.url, identity: $0.liveIdentity(), dataless: $0.isDataless) }
        let group = UUID()
        let outcome = await Task.detached(priority: .userInitiated) { () -> (verified: [TagWriteResult], failed: Int, refusal: String?, unfinished: [String]) in
            var notes: [String: (kind: String?, reader: String?)] = [:]
            for item in items where !item.dataless { notes[item.url.path] = TextPageSummary.read(item.url).ledgerNote }
            var verified: [TagWriteResult] = []
            var failed = 0
            var refusal: String?
            let unfinished = PoorOCRFlagGuard.Unfinished()
            PoorOCRFlagGuard.$unfinished.withValue(unfinished) { PoorOCRFlagGuard.$annotations.withValue(notes) {
                AuditLedger.withContext(group: group) {
                    for item in items {
                        do { verified.append(try TagWriter.apply(delta, to: item.url, expecting: item.identity)) }
                        catch let r as PoorOCRFlagGuard.Refusal { failed += 1; refusal = refusal ?? r.description }
                        catch { failed += 1 }
                    }
                }
            } }
            return (verified, failed, refusal, unfinished.names)
        }.value
        // The batch ran off the main thread, so a tag edit made meanwhile may have reached the row first. A result
        // is shown only while the file still reads as it left it; otherwise the later write's row stands.
        let current = outcome.verified.filter { r in
            guard case let .success(names, _) = TagReading.read(r.url) else { return false }
            return multisetEqual(names, r.after)
        }
        library.applyVerifiedWrites(current)
        refreshUndoHistory()
        let done = outcome.verified.count, failed = outcome.failed + reverified.rejected
        var message = flag ? "Flagged \(done) file\(done == 1 ? "" : "s") as poor OCR."
            : "Removed the poor-OCR flag from \(done) file\(done == 1 ? "" : "s")."
        if failed > 0 { message += " \(failed) could not be changed" + (outcome.refusal.map { ": \($0)" } ?? ".") }
        if !outcome.unfinished.isEmpty {
            message += " The flag record of \(outcome.unfinished.prefix(3).joined(separator: ", ")) could not be finished;"
                + " Archive Processor will treat a review of those files as out of date."
        }
        statusMessage = message
        announce(statusMessage)
        return outcome.verified
    }

    // MARK: The shared folder

    /// The Improve OCR folder is connected and usable, or the person connects it now. False after a cancel or a
    /// folder that cannot be used, with the reason on the status line.
    func connectImproveOCRFolderIfNeeded() -> Bool {
        let support = ImproveOCRSupport.shared
        if support.isConnected {
            do { _ = try support.resolve(); return true } catch {
                statusMessage = "\(error)"
                announce(statusMessage)
                return chooseImproveOCRFolder()
            }
        }
        return chooseImproveOCRFolder()
    }

    /// File ▸ Connect Improve OCR Folder…: the folder Archive Processor uses too. It holds the flag records and the
    /// hand-off lists, never a document, and is never inside the archive.
    @discardableResult
    func chooseImproveOCRFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Connect"
        panel.message = "Choose the Improve OCR folder that Archive Processor uses — normally “ImproveOCR” inside "
            + "Application Support ▸ ArchiveSuite in your Library (create it if it is not there). It holds the poor-OCR "
            + "flag records and the lists of files sent to the Processor, never your documents."
        panel.directoryURL = ImproveOCRSupport.suggestedPanelLocation()
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try ImproveOCRSupport.shared.connect(url)
            statusMessage = "Connected the Improve OCR folder “\(url.lastPathComponent)”."
            announce(statusMessage)
            return true
        } catch {
            statusMessage = "\(error)"
            announce(statusMessage)
            return false
        }
    }

    // MARK: Improve OCR…

    /// Opens Archive Processor's Improve OCR dialog on the targets. The Processor reads the files only after the
    /// person chooses a reader there; this sends no text and changes nothing.
    func improveOCR(paths: [String]? = nil) {
        let targets = tagTargets(paths).filter { isInsideMainArchive($0.url) }
        guard !targets.isEmpty else {
            statusMessage = ImproveOCRHandoff.Problem.nothingToSend.description
            announce(statusMessage)
            return
        }
        guard let opener = ImproveOCROpener.current else {
            statusMessage = "Install Archive Processor to improve OCR. The flags stay on the files until then."
            announce(statusMessage)
            return
        }
        guard connectImproveOCRFolderIfNeeded() else { return }
        let urls = targets.map(\.url)
        Task { [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let support = try ImproveOCRSupport.shared.resolve()
                    return try ImproveOCRHandoff.link(for: urls, archive: .shared, support: support)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                statusMessage = "\(error)"
                announce(statusMessage)
            case .success(let link):
                let n = urls.count
                statusMessage = "Opening Archive Processor to improve the OCR of \(n) file\(n == 1 ? "" : "s")…"
                announce(statusMessage)
                opener.open(link) { [weak self] problem in
                    guard let self, let problem else { return }
                    self.statusMessage = "Archive Processor could not be opened (\(problem)). Choose Improve OCR… again to retry."
                    self.announce(self.statusMessage)
                }
            }
        }
    }
}

extension NavigationModel {
    // MARK: Receipts: the Processor replaced a file's text

    /// Reads the Processor's unseen receipts and, for each file in this archive, drops its index row (the
    /// replacement kept the file's dates, so an ordinary pass would skip it), starts the incremental pass that
    /// extracts it again, and reloads a document window showing it. Called on each library change and when the app
    /// comes forward; also every 20 seconds while a folder is connected. Cheap when there is nothing new: one
    /// folder listing.
    func checkImproveOCRReceipts() {
        let support = ImproveOCRSupport.shared
        guard support.isConnected, !ImproveOCRReceiptCheck.running else { return }
        ImproveOCRReceiptCheck.startTimer { [weak self] in self?.checkImproveOCRReceipts() }
        guard let folder = try? support.resolve() else { return }
        let inbox = ImproveOCRReceiptInbox(defaults: support.defaults)
        let unseen = inbox.unseen(in: folder)
        guard !unseen.isEmpty else { return }
        var refresh: [String] = [], seen: [UUID] = []
        var paths: [String]?
        let candidates: () -> [String] = { [library] in
            if let paths { return paths }
            let all = library.files.map(\.path)
            paths = all
            return all
        }
        for item in unseen {
            switch ImproveOCRReceiptInbox.disposition(of: item.receipt, archive: .shared, candidates: candidates) {
            case .refresh(let path): refresh.append(path); seen.append(item.id)
            case .drop: seen.append(item.id)
            case .notHere: break
            }
        }
        let unique = Array(Set(refresh))
        ImproveOCRReceiptCheck.running = true
        Task {
            defer { ImproveOCRReceiptCheck.running = false }
            guard await indexer.forget(unique) else { return }   // left unseen: the next check tries again
            if !unique.isEmpty {
                indexer.startIndexing(indexableFiles(library.files))
                NotificationCenter.default.post(name: .readerFileContentsReplaced, object: nil,
                                                userInfo: [ReaderFileContentsReplaced.pathsKey: unique])
            }
            inbox.markSeen(seen)
        }
    }
}

/// One receipt check at a time, and the timer that repeats it.
@MainActor
enum ImproveOCRReceiptCheck {
    static var running = false
    private static var timer: Timer?

    static func startTimer(_ check: @escaping @MainActor () -> Void) {
        guard timer == nil, !ArchiveTestHost.isUnitTestHost else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            MainActor.assumeIsolated { check() }
        }
    }
}

/// How the hand-off link is opened: Launch Services, or (DEBUG UITest launches with `-ARUITestImproveOCRHandoff`)
/// a recorder that shows the link on the status line instead, since no Processor is installed in the test VM.
@MainActor
struct ImproveOCROpener {
    let open: (URL, @escaping @MainActor (String?) -> Void) -> Void

    static var current: ImproveOCROpener? {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ARUITestImproveOCRHandoff") {
            return ImproveOCROpener { url, done in
                recorded = url
                done(nil)
            }
        }
#endif
        guard let probe = URL(string: "\(ImproveOCRRequest.scheme)://\(ImproveOCRRequest.host)"),
              NSWorkspace.shared.urlForApplication(toOpen: probe) != nil else { return nil }
        return ImproveOCROpener { url, done in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                let why = error?.localizedDescription
                Task { @MainActor in done(why) }
            }
        }
    }

    /// The last link the DEBUG recorder received.
    static var recorded: URL?
}

/// The Kind and reader of a PDF's text pages, from their headers (`PDFHeaderParser`), for display and the ledger.
/// Read-only; the caller keeps dataless files away.
struct TextPageSummary: Equatable, Sendable {
    var kind: PDFMetadataSummary<OCRPageKind>
    var reader: PDFMetadataSummary<PDFReaderProvenance>

    static let unknown = TextPageSummary(kind: .unknown, reader: .unknown)

    static func read(_ url: URL) -> TextPageSummary {
        CorpusWalker.withDatalessMaterializationDisabled {
            guard let doc = PDFDocument(url: url), !doc.isLocked else { return .unknown }
            return summarize((0..<doc.pageCount).filter { $0 % 2 == 1 }.compactMap { doc.page(at: $0) })
        }
    }

    static func summarize(_ textPages: [PDFPage]) -> TextPageSummary {
        let headers = textPages.map { PDFHeaderParser.parse($0).header }
        return TextPageSummary(kind: summary(headers.map { $0?.kind }), reader: summary(headers.map { $0?.provenance }))
    }

    /// As ArchiveCore's `ExtractedContent` summaries: unknown when no page names one, mixed when a page differs or
    /// names none beside one that does, so one page's Kind is never applied to the whole file.
    static func summary<V: Equatable & Sendable>(_ values: [V?]) -> PDFMetadataSummary<V> {
        guard values.contains(where: { $0 != nil }) else { return .unknown }
        guard let first = values.first, let first else { return .mixed }
        return values.allSatisfy { $0 == first } ? .uniform(first) : .mixed
    }

    /// "Typewritten", "Mixed", or nil when no text page names one.
    var kindLabel: String? {
        switch kind {
        case .unknown: nil
        case .uniform(let k): k.displayName
        case .mixed: "Mixed"
        }
    }

    /// "Gemini · gemini-3.7-flash", "Mixed", or nil.
    var readerLabel: String? {
        switch reader {
        case .unknown: nil
        case .uniform(let r): "\(r.provider) · \(r.model)"
        case .mixed: "Mixed"
        }
    }

    var ledgerNote: (kind: String?, reader: String?) {
        let k: String? = switch kind { case .unknown: nil; case .uniform(let v): v.rawValue; case .mixed: "mixed" }
        return (k, readerLabel)
    }
}
