import ArchiveCore
import Foundation

/// The archive's Finder mirror in the Reader (W49.storage-finder-reader-mirror; owner, 2026-11-27,
/// `W49.storage-finder-owner-ok`). Off unless the open archive turns it on (File ▸ Mirror Archive Fields to Finder
/// Tags), which records the choice in the archive's settings document so the Processor agrees. With it on:
/// each saved catalogue change is projected to the PDF's Finder tags through `FinderMirror` (only tokens the suite
/// wrote are ever replaced); turning it on projects every record once, in the background, cancellably, and can be
/// resumed; a mirrored tag changed in Finder is shown in the Inspector with Import and Re-publish, never taken or
/// overwritten silently (2b); turning it off can also Remove Suite Tags, which File ▸ Put Back Suite Tags undoes (3b).
extension NavigationModel {
    enum FinderMirrorPrompt: Identifiable, Equatable {
        case turnOn(pdfs: Int)
        case turnOff

        var id: String {
            switch self {
            case .turnOn: "on"
            case .turnOff: "off"
            }
        }
    }

    private var finderMirrorPendingKey: String? {
        catalogueReader.map { "readerFinderMirror.backfillPending.\($0.rootInstanceID.uuidString)" }
    }

    // MARK: The switch

    /// Read the open archive's choice. Called when a library starts.
    func loadFinderMirrorSetting() {
        finderMirrorTask?.cancel()
        finderMirrorTask = nil
        finderMirrorProgress = nil
        finderMirrorDivergences = [:]
        finderMirrorAccepting = []
        guard let root = rootStore.root else {
            finderMirrorOn = false
            return
        }
        finderMirrorOn = ((try? ArchiveSettings.read(root: root)) ?? nil)?.mirrorFinderTags ?? false
        finderMirrorRemovalsAvailable = FinderMirrorRemovals.exists(for: root)
    }

    /// Whether turning mirroring on or off is open now: catalogue mode, and no mirror job or catalogue save running.
    var canChangeFinderMirror: Bool {
        rootStore.root != nil && library.usesCatalogue && catalogueSnapshot != nil && !catalogueEditSaving
            && finderMirrorTask == nil
    }

    var finderMirrorBackfillPending: Bool {
        finderMirrorOn && finderMirrorPendingKey.map { defaults.bool(forKey: $0) } == true
    }

    /// The menu's toggle asks first: what turning on writes, or whether to remove the suite's tags on turning off.
    func requestFinderMirror(_ on: Bool) {
        guard canChangeFinderMirror, on != finderMirrorOn else { return }
        finderMirrorPrompt = on ? .turnOn(pdfs: catalogueSnapshot?.inventory.relativePDFPaths.count ?? 0) : .turnOff
    }

    func confirmFinderMirror(on: Bool, removingSuiteTags: Bool = false) {
        finderMirrorPrompt = nil
        guard let root = rootStore.root, canChangeFinderMirror else { return }
        do {
            try ArchiveSettings.write(ArchiveSettings(mirrorFinderTags: on), root: root)
        } catch {
            reportCatalogue("The archive's Finder tag setting could not be saved: \(error.localizedDescription)")
            return
        }
        finderMirrorOn = on
        finderMirrorDivergences = [:]
        if on {
            if let key = finderMirrorPendingKey { defaults.set(true, forKey: key) }
            startFinderMirrorBackfill()
        } else {
            if let key = finderMirrorPendingKey { defaults.removeObject(forKey: key) }
            if removingSuiteTags {
                removeSuiteFinderTags()
            } else {
                reportCatalogue("Finder tags are no longer kept up to date. Tags already on the PDFs stay and may go out of date.")
            }
        }
    }

    func cancelFinderMirrorJob() {
        finderMirrorTask?.cancel()
    }

    // MARK: Projection

    /// Project the records a save changed, and every listed PDF that shows a document one of them owns.
    func projectFinderMirror(changedRecords: [String]) {
        let changed = Set(changedRecords)
        var affected = changed
        if let rootPath = rootStore.discoveredPathPrefix {
            for row in library.files where row.isCatalogue {
                guard let owner = (try? row.catalogueFacts?.document.get())?.owner.pair.occurrence.relativePath,
                      changed.contains(owner),
                      let relative = ReaderCatalogueScan.relativePath(of: row.url, under: rootPath) else { continue }
                affected.insert(relative)
            }
        }
        let accepting = finderMirrorAccepting.intersection(affected)
        finderMirrorAccepting.subtract(accepting)
        runFinderMirror(paths: affected.sorted(), accepting: accepting, backfill: false)
    }

    /// Turning on, or resuming after an interruption: every record in the archive, in the background.
    func startFinderMirrorBackfill() {
        guard let paths = catalogueSnapshot?.inventory.relativePDFPaths else { return }
        runFinderMirror(paths: paths, accepting: [], backfill: true)
    }

    private func runFinderMirror(paths: [String], accepting: Set<String>, backfill: Bool) {
        guard let reader = catalogueReader, let root = rootStore.root, !paths.isEmpty else { return }
        finderMirrorTask?.cancel()
        let pendingKey = finderMirrorPendingKey
        finderMirrorTask = Task { [weak self] in
            var report = FinderMirrorWork.Report()
            let chunks = stride(from: 0, to: paths.count, by: 100).map { Array(paths[$0..<min($0 + 100, paths.count)]) }
            for chunk in chunks {
                if Task.isCancelled { break }
                let part = await Task.detached(priority: .utility) {
                    FinderMirrorWork.publish(chunk, reader: reader, root: root, accepting: accepting)
                }.value
                report.merge(part)
                guard let self, self.catalogueReader?.rootInstanceID == reader.rootInstanceID else { return }
                self.finderMirrorDivergences.merge(part.diverged) { _, new in new }
                for path in part.published { self.finderMirrorDivergences[path] = nil }
                self.reviseAfterFinderMirror(part.writtenPaths)
                if backfill { self.finderMirrorProgress = "Mirroring Finder tags: \(report.done) of \(paths.count)…" }
            }
            guard let self, self.catalogueReader?.rootInstanceID == reader.rootInstanceID else { return }
            let cancelled = Task.isCancelled
            self.finderMirrorTask = nil
            self.finderMirrorProgress = nil
            if backfill, !cancelled, let pendingKey { self.defaults.removeObject(forKey: pendingKey) }
            if backfill || !report.isQuiet {
                self.reportCatalogue(report.message(backfill: backfill, cancelled: cancelled, total: paths.count))
            }
            if !report.failures.isEmpty { self.catalogueEditFailures = report.failures }
        }
    }

    /// A tag write changes the PDF's change time, which the catalogue's edit base checks: re-read those PDFs so the
    /// next save is based on them (the library hears no file events for the Reader's own writes).
    private func reviseAfterFinderMirror(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        library.reviseCatalogue(relativePaths: paths)
    }

    // MARK: A Finder edit (2b)

    /// Look again at one PDF's tags against its ownership record; the Inspector calls this for its selection.
    func checkFinderMirror(relativePath: String) {
        guard finderMirrorOn, let root = rootStore.root else { return }
        let url = root.appendingPathComponent(relativePath)
        Task { [weak self] in
            let divergence = await Task.detached(priority: .userInitiated) { FinderMirrorWork.divergence(at: url) }.value
            guard let self, self.finderMirrorOn, self.rootStore.root == root else { return }
            if self.finderMirrorDivergences[relativePath] != divergence {
                self.finderMirrorDivergences[relativePath] = divergence
            }
        }
    }

    /// Re-publish: put the record's values back over the Finder edit.
    func republishFinderMirror(relativePath: String) {
        runFinderMirror(paths: [relativePath], accepting: [relativePath], backfill: false)
    }

    /// Import: the Finder values of the facets that changed become user edits of the record; the mirror is then
    /// re-projected from the record, accepting the Finder tags as the new baseline.
    func importFinderMirror(relativePath: String) {
        guard let root = rootStore.root, let rootPath = rootStore.discoveredPathPrefix,
              let divergence = finderMirrorDivergences[relativePath] else { return }
        let url = root.appendingPathComponent(relativePath)
        guard case .success(let names, let label) = TagReading.read(url) else {
            reportCatalogue("The Finder tags of “\(relativePath)” could not be read.")
            return
        }
        let plan = FinderMirrorImport(divergence: divergence, tags: names, label: label)
        finderMirrorAccepting.insert(relativePath)
        let rowPath = URL(fileURLWithPath: rootPath).appendingPathComponent(relativePath).path
        let started = editCatalogue(title: "Import Finder Tags", paths: [rowPath]) { facts in plan.edits(for: facts) }
        if !started {
            finderMirrorAccepting.remove(relativePath)
            // Nothing in the record differs from Finder: only the mirror's baseline is out of date.
            republishFinderMirror(relativePath: relativePath)
        }
    }

    // MARK: Remove Suite Tags (3b)

    /// Remove, from every PDF in the archive, only the tags its ownership record says the suite wrote. What was
    /// removed is kept in Application Support so File ▸ Put Back Suite Tags can undo it.
    func removeSuiteFinderTags() {
        guard let root = rootStore.root, let paths = catalogueSnapshot?.inventory.relativePDFPaths else { return }
        finderMirrorTask?.cancel()
        finderMirrorTask = Task { [weak self] in
            var removals: [String: FinderMirror.Removal] = [:]
            var failures: [String] = []
            let chunks = stride(from: 0, to: paths.count, by: 200).map { Array(paths[$0..<min($0 + 200, paths.count)]) }
            for chunk in chunks {
                if Task.isCancelled { break }
                let part = await Task.detached(priority: .utility) { FinderMirrorWork.remove(chunk, root: root) }.value
                removals.merge(part.removals) { _, new in new }
                failures += part.failures
                self?.reviseAfterFinderMirror(Array(part.removals.keys))
                self?.finderMirrorProgress = "Removing suite tags: \(removals.count) PDFs so far…"
            }
            let cancelled = Task.isCancelled
            let saved = removals.isEmpty || (try? FinderMirrorRemovals.save(removals, for: root)) != nil
            guard let self else { return }
            self.finderMirrorTask = nil
            self.finderMirrorProgress = nil
            self.finderMirrorRemovalsAvailable = FinderMirrorRemovals.exists(for: root)
            self.catalogueEditFailures = failures
            var message = removals.isEmpty
                ? "No PDF had tags the suite recorded writing."
                : "Removed the suite's Finder tags from \(removals.count) PDF(s); your own tags stayed."
            if cancelled { message += " Stopped before the end." }
            if !failures.isEmpty { message += " \(failures.count) PDF(s) could not be changed." }
            message += saved ? (removals.isEmpty ? "" : " File ▸ Put Back Suite Tags undoes this.")
                : " What was removed could not be saved, so this cannot be undone."
            self.reportCatalogue(message)
        }
    }

    /// Undo the last Remove Suite Tags: put back each removed tag the PDF lacks, and record it as the suite's again.
    func putBackSuiteFinderTags() {
        guard let root = rootStore.root, finderMirrorTask == nil,
              let removals = try? FinderMirrorRemovals.load(for: root) else { return }
        finderMirrorTask = Task { [weak self] in
            let failures = await Task.detached(priority: .utility) { FinderMirrorWork.restore(removals, root: root) }.value
            if failures.isEmpty { try? FinderMirrorRemovals.discard(for: root) }
            guard let self else { return }
            self.reviseAfterFinderMirror(Array(removals.keys))
            self.finderMirrorTask = nil
            self.finderMirrorRemovalsAvailable = FinderMirrorRemovals.exists(for: root)
            self.catalogueEditFailures = failures
            self.reportCatalogue(failures.isEmpty
                ? "Put back the suite's Finder tags on \(removals.count) PDF(s)."
                : "Put back the suite's Finder tags; \(failures.count) PDF(s) could not be changed and stay listed for another try.")
        }
    }
}

/// The off-main work of the mirror: one PDF at a time, each through `FinderMirror` and its coordinated writer.
enum FinderMirrorWork {
    struct Report: Sendable {
        var done = 0
        var written = 0
        var writtenPaths: [String] = []
        var published: [String] = []
        var diverged: [String: FinderMirror.Divergence] = [:]
        var unknown = 0
        var noRecord = 0
        /// PDFs keeping vocabulary tags the suite did not write that disagree with their record.
        var disagreeing = 0
        var failures: [String] = []

        var isQuiet: Bool { diverged.isEmpty && unknown == 0 && failures.isEmpty }

        mutating func merge(_ other: Report) {
            done += other.done
            written += other.written
            writtenPaths += other.writtenPaths
            published += other.published
            diverged.merge(other.diverged) { _, new in new }
            unknown += other.unknown
            noRecord += other.noRecord
            disagreeing += other.disagreeing
            failures += other.failures
        }

        func message(backfill: Bool, cancelled: Bool, total: Int) -> String {
            var parts: [String] = []
            if backfill {
                parts.append(cancelled
                    ? "Stopped mirroring Finder tags after \(done) of \(total) PDFs; File ▸ Resume Mirroring to Finder Tags goes on."
                    : "Finder tags now mirror the catalogue records of \(done - noRecord) PDF(s) (\(written) changed).")
            }
            if !diverged.isEmpty {
                parts.append("\(diverged.count) PDF(s) have Finder tags changed outside Archive Suite and were left as they are; the Inspector offers Import or Re-publish.")
            }
            if disagreeing > 0 {
                parts.append("\(disagreeing) PDF(s) keep older tags the suite did not write that disagree with their records; they were left.")
            }
            if unknown > 0 { parts.append("\(unknown) PDF(s) carry a record of suite tags from a newer version and were left.") }
            if !failures.isEmpty { parts.append("\(failures.count) PDF(s) could not be changed.") }
            return parts.joined(separator: " ")
        }
    }

    static func publish(_ paths: [String], reader: CatalogueReader, root: URL, accepting: Set<String>) -> Report {
        var report = Report()
        let scope = reader.snapshot(.init(relativePDFPaths: [], isComplete: false), including: paths)
        for path in paths {
            report.done += 1
            let facts = scope.facts(at: path)
            guard let file = try? facts.file.get() else {
                report.noRecord += 1
                continue
            }
            let projection = FinderMirror.projection(file: file.pair.record.fileFields,
                                                     document: (try? facts.document.get())?.document.fields)
            let url = root.appendingPathComponent(path)
            do {
                switch try FinderMirror.publish(url, projection: projection, expectedIdentity: FileIdentity.capture(url),
                                                republishing: accepting.contains(path)) {
                case .published(let result):
                    report.published.append(path)
                    if !result.isNoOp {
                        report.written += 1
                        report.writtenPaths.append(path)
                    }
                    let wanted = projection.tokens + (projection.label.map { [$0.tokenName] } ?? [])
                    if result.after.contains(where: { token in
                        FinderMirror.isFacetToken(token) && !FinderLabel.isColourName(token)
                            && !wanted.contains { isSameTag($0, token) }
                    }) { report.disagreeing += 1 }
                case .diverged(let divergence):
                    report.diverged[path] = divergence
                case .unknownLedger:
                    report.unknown += 1
                }
            } catch {
                report.failures.append("“\(path)”: \(error.localizedDescription)")
            }
        }
        return report
    }

    static func divergence(at url: URL) -> FinderMirror.Divergence? {
        guard case .success(let names, let label) = TagReading.read(url) else { return nil }
        return FinderMirror.divergence(current: names, label: label, ledger: FinderMirror.readLedger(url).ledger)
    }

    struct Removed: Sendable {
        var removals: [String: FinderMirror.Removal] = [:]
        var failures: [String] = []
    }

    static func remove(_ paths: [String], root: URL) -> Removed {
        var out = Removed()
        for path in paths {
            let url = root.appendingPathComponent(path)
            do {
                if let removal = try FinderMirror.removeSuiteTags(url, expectedIdentity: FileIdentity.capture(url)) {
                    out.removals[path] = removal
                }
            } catch {
                out.failures.append("“\(path)”: \(error.localizedDescription)")
            }
        }
        return out
    }

    static func restore(_ removals: [String: FinderMirror.Removal], root: URL) -> [String] {
        var failures: [String] = []
        for (path, removal) in removals.sorted(by: { $0.key < $1.key }) {
            let url = root.appendingPathComponent(path)
            do {
                try FinderMirror.restoreSuiteTags(url, removal: removal, expectedIdentity: FileIdentity.capture(url))
            } catch {
                failures.append("“\(path)”: \(error.localizedDescription)")
            }
        }
        return failures
    }
}

/// The record edits that take a Finder edit's values: only the facets the divergence touched, read from the
/// file's current tags. A subject is imported only as a removal of one the suite wrote (an added one could be
/// the user's own tag, so it is never read into the record).
struct FinderMirrorImport: Sendable {
    let divergence: FinderMirror.Divergence
    let tags: [String]
    let label: Int?

    private enum Facet: Hashable { case date, sentWith, quality, readState, itemType, ocrPoor, colour, check(CheckableField), subject }

    private static func facet(of token: String) -> Facet? {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        if FinderLabel.isColourName(trimmed) { return .colour }
        if trimmed.caseInsensitiveCompare("OCR Failed") == .orderedSame { return nil }
        let parsed = DocumentTags.parse(raw: [trimmed], labelNumber: nil)
        if parsed.hasPoorOCR { return .ocrPoor }
        if parsed.year != nil || parsed.month != nil || parsed.day != nil || parsed.decade != nil || parsed.dateUncertain {
            return .date
        }
        if parsed.sentWith != nil || parsed.sentWithUncertain { return .sentWith }
        if parsed.quality != nil { return .quality }
        if parsed.readState != nil { return .readState }
        if parsed.itemType != nil { return .itemType }
        if let field = parsed.checkedFields.first { return .check(field) }
        return .subject
    }

    func edits(for facts: ItemFacts) -> [(ItemFacts.FileFacts, CatalogueEdit)] {
        guard let file = try? facts.file.get() else { return [] }
        let finder = DocumentTags.parse(raw: tags, labelNumber: label)
        let facets = Set((divergence.removed + divergence.added).compactMap(Self.facet(of:)))
            .union(divergence.labelChanged ? [.colour] : [])
        let owner = try? facts.document.get()
        let fields = owner?.document.fields
        var out: [(ItemFacts.FileFacts, CatalogueEdit)] = []
        func fileEdit(_ field: CatalogueEdit.FileField, _ change: CatalogueEdit.Change) {
            out.append((file, CatalogueEdit(.file(field), change)))
        }
        func documentEdit(_ field: CatalogueEdit.DocumentField, _ change: CatalogueEdit.Change) {
            guard let owner else { return }
            out.append((owner.owner, CatalogueEdit(.document(owner.document.id, field), change)))
        }
        var valueSet: Set<CatalogueEdit.DocumentField> = []
        for facet in facets {
            switch facet {
            case .date:
                let date = finder.decade.flatMap { ArchiveDate(decade: $0) }
                    ?? finder.year.flatMap { ArchiveDate(year: $0, month: finder.month?.number, day: finder.day) }
                documentEdit(.documentDate, date.map { .set(.date(.init(date: $0, uncertain: finder.dateUncertain))) } ?? .clear)
                valueSet.insert(.documentDate)
            case .sentWith:
                documentEdit(.sentWith, finder.sentWith.map { .set(.date(.init(date: $0, uncertain: finder.sentWithUncertain))) } ?? .clear)
                valueSet.insert(.sentWith)
            case .quality:
                fileEdit(.quality, finder.quality.map { .set(.rating($0)) } ?? .clear)
            case .readState:
                fileEdit(.readState, finder.readState.map { .set(.text($0.rawValue.lowercased())) } ?? .clear)
            case .itemType:
                documentEdit(.itemType, finder.itemType.map { .set(.text($0.rawValue)) } ?? .clear)
                valueSet.insert(.itemType)
            case .ocrPoor:
                fileEdit(.ocrPoor, .set(.flag(finder.hasPoorOCR)))
            case .colour:
                fileEdit(.colour, FinderLabel(labelNumber: label).map { .set(.text($0.tokenName.lowercased())) } ?? .clear)
            case .subject:
                let removed = divergence.removed.filter { Self.facet(of: $0) == .subject }
                guard !removed.isEmpty, let subjects = NavigationModel.value(fields?.subjects) else { continue }
                let kept = subjects.filter { subject in !removed.contains { isSameTag($0, subject) } }
                if kept != subjects { documentEdit(.subjects, .set(.names(kept))) }
            case .check:
                continue
            }
        }
        // A check follows its tag, on a field that has a value and whose value is not being replaced here.
        for facet in facets {
            guard case .check(let checkable) = facet, let field = NavigationModel.catalogueField(checkable),
                  !valueSet.contains(field), Self.hasValue(field, in: fields) else { continue }
            documentEdit(field, .check(finder.checkedFields.contains(checkable)))
        }
        return out
    }

    private static func hasValue(_ field: CatalogueEdit.DocumentField, in fields: CatalogueRecord.DocumentFields?) -> Bool {
        guard let fields else { return false }
        switch field {
        case .documentDate: return NavigationModel.value(fields.documentDate) != nil
        case .sentWith: return NavigationModel.value(fields.sentWith) != nil
        case .publicationDate: return NavigationModel.value(fields.publicationDate) != nil
        case .documentKind: return NavigationModel.value(fields.documentKind) != nil
        case .itemType: return NavigationModel.value(fields.itemType) != nil
        case .title: return NavigationModel.value(fields.title) != nil
        case .byline: return NavigationModel.value(fields.byline) != nil
        case .publication: return NavigationModel.value(fields.publication) != nil
        case .senders: return NavigationModel.value(fields.senders) != nil
        case .recipients: return NavigationModel.value(fields.recipients) != nil
        case .sendingPlaces: return NavigationModel.value(fields.sendingPlaces) != nil
        case .recipientPlaces: return NavigationModel.value(fields.recipientPlaces) != nil
        case .subjects: return NavigationModel.value(fields.subjects) != nil
        }
    }
}

/// What the last Remove Suite Tags took off, per archive root, so it can be put back. In the Reader's Application
/// Support, never in the archive.
enum FinderMirrorRemovals {
    private static func url(for root: URL) -> URL? {
        guard let identity = ReaderRootIdentity.capture(root),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        return support.appendingPathComponent("ArchiveReader/FinderMirrorRemovals", isDirectory: true)
            .appendingPathComponent("\(identity.key).json")
    }

    static func exists(for root: URL) -> Bool {
        url(for: root).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    static func load(for root: URL) throws -> [String: FinderMirror.Removal] {
        guard let url = url(for: root) else { throw CocoaError(.fileNoSuchFile) }
        return try JSONDecoder().decode([String: FinderMirror.Removal].self, from: Data(contentsOf: url))
    }

    /// Merged with any earlier removal not yet put back, so a second removal never loses the first one's undo.
    static func save(_ removals: [String: FinderMirror.Removal], for root: URL) throws {
        guard let url = url(for: root) else { throw CocoaError(.fileNoSuchFile) }
        let removals = ((try? load(for: root)) ?? [:]).merging(removals) { _, new in new }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(removals).write(to: url, options: .atomic)
    }

    static func discard(for root: URL) throws {
        guard let url = url(for: root) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
