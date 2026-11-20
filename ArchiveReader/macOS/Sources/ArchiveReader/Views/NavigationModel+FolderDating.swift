import Foundation
import PDFKit
import ArchiveCore

// MARK: - A folder date confirmed here dates the documents already written (W47.ct-folder-date-reader, Tier-2)
//
// Process Files applies the owner's folder-date rule as it tags (W47.ct-folder-date), but it records label reads as
// proposals, so a folder date usually becomes confirmed here, after the documents are written. When the user confirms or
// changes a folder run's date in the Container section, the Reader offers to date the run's documents that have no date
// of their own (`ContainerFolderDate.dates`), as the dating route would have: the Year or Decade, Month and Date
// Uncertain tags through `TagWriter` (one ledger group, so one Undo), never a check. Page 2 is never rewritten, so the
// `Date evidence:` value goes beside the files, in `.archivesuite/item-fields.json` (`FolderDateRecord`), written first:
// if it cannot be saved nothing is dated. The record is trusted only while the file carries the date it gave, so undoing
// the tags needs no second write. `SPEC/containers.md` §The folder-date rule.
//
// W49.reader-folder-date-undo (owner, 2026-11-19, call 21): the dates a folder gave follow its date. Any edit of a
// folder run's date (Change…, Confirm, None Here, Remove Your Value) offers it again: a date that still dates replaces
// the dates the folder gave as well as the undated ones (`ContainerFolderDate.dates`); one that dates nothing (cleared,
// no longer confirmed, 20 years or more) takes the dates the folder gave away, putting back the stamp's or estimate's
// date page 2 records where there is one (`ContainerFolderDate.undatingDelta`). A date the user changed or checked
// since, or one from the file itself, stands. One ledger group, so one Undo; the records are kept, so Undo restores
// the date with its evidence.

/// The offer made after a folder date is confirmed: which documents it would date.
struct FolderDatingOffer: Identifiable, Equatable {
    let id = UUID()
    /// The folder date the files take; nil takes away the dates the folder gave (W49.reader-folder-date-undo).
    let date: ContainerFolderDate?
    let treePath: String
    /// The folder below the tree's root, and the file the date was saved at.
    let directory: [String]
    let editedName: String
    /// The files whose tags change, in the folder's order.
    let paths: [String]
    /// Every file that takes the date (those already reading so too): each gets the evidence record.
    let recorded: [String]
    /// What each file's date rested on when the offer was made.
    let evidence: [String: FolderDatingEvidence]
    /// The window the edit was made in, whose Inspector asks; nil asks in any.
    let window: ObjectIdentifier?

    private var count: String { "\(paths.count) document\(paths.count == 1 ? "" : "s")" }

    var title: String {
        let folder = "“\(directory.last ?? "the folder")”"
        return date == nil ? "Take the folder's date from \(count) in \(folder)?"
            : "Date \(count) in \(folder) from the folder?"
    }

    var message: String {
        let undo = "Edit ▸ Undo Tag Change (⌘Z) takes it back."
        guard let date else {
            let them = paths.count == 1 ? "1 document in it was" : "\(paths.count) documents in it were"
            return "The folder no longer gives a date. \(them) dated from the folder's date; each goes back to the "
                + "stamp's or estimate's date it had, or to no date. Dates you changed or checked since, and dates "
                + "from a document's own text or page image, are left as they are. " + undo
        }
        let shown = date.inheritedDate.map { $0.date.display + ($0.uncertain ? ", marked uncertain" : "") } ?? ""
        let them = paths.count == 1 ? "1 document in it has" : "\(paths.count) documents in it have"
        return "The folder is dated “\(date.text)”. \(them) no date of its own, or one only estimated, taken from a "
            + "stamp or given by the folder's earlier date; each would be dated \(shown). Dates read from a "
            + "document's text or page image, checked dates and the folder photo are left as they are. " + undo
    }

    var confirmTitle: String {
        let n = "\(paths.count) Document\(paths.count == 1 ? "" : "s")"
        return date == nil ? "Update \(n)" : "Date \(n)"
    }
}

/// What a file's date rests on: page 2's `Date evidence:` line, a record of a folder date the Reader gave it, and
/// whether page 2 says it is a box or folder photo.
struct FolderDatingEvidence: Equatable, Sendable {
    var page: String?
    var record: FolderDateRecord?
    var containerPhoto = false
}

/// The folder's date was undone, removed or changed between the offer and its answer.
struct FolderDateChanged: LocalizedError {
    var errorDescription: String? { "the folder's date changed since it was offered, so no document was changed." }
}

/// Whether the folder run an edit was made in had a confirmed date that dates documents just before the edit, set by
/// the edit's work off the main thread and read after it finished (W49.reader-folder-date-undo). Only then can a date
/// that dates nothing take away the dates the folder gave: a box's date, an edit that changed nothing, or a run whose
/// folder evidence came from elsewhere (Live Capture's cards) offers no undating.
final class FolderDateBefore: @unchecked Sendable {
    var dated = false
}

/// A folder run whose confirmed date can date documents: the date, the folder on disk and the run's files.
struct FolderDatingRun: Sendable {
    /// Nil when the run's date dates nothing (`NavigationModel.folderDateRun`).
    let date: ContainerFolderDate?
    let directory: URL
    let names: [String]
}

extension NavigationModel {
    /// After the folder date at `path` was saved: works out which documents it dates and, if any, offers it. A date
    /// that dates nothing offers to take away the dates the folder gave, where it dated before the edit (`datedBefore`).
    func offerFolderDating(at path: String, window: ObjectIdentifier?, datedBefore: Bool = true) {
        guard let tree = containerTree, let (dir, name) = ContainerCatalog.split(path, under: tree.path) else { return }
        Task { [weak self] in
            let run = await Task.detached(priority: .userInitiated) {
                Self.folderDateRun(tree: tree.url, components: dir, editedName: name)
            }.value
            guard let self, let run, run.date != nil || datedBefore, tree.path == self.containerTree?.path else { return }
            let base = ([tree.path.hasSuffix("/") ? String(tree.path.dropLast()) : tree.path] + dir)
                .joined(separator: "/")
            let files = self.libraryFiles(atPaths: run.names.map { base + "/" + $0 })
                .filter { $0.url.pathExtension.lowercased() == "pdf" && $0.itemType == nil }
            let reads = files.map { (path: $0.path, url: $0.url, dataless: $0.isDataless) }
            let evidence = await Task.detached(priority: .userInitiated) {
                Self.folderDatingEvidence(reads, directory: run.directory)
            }.value
            guard tree.path == self.containerTree?.path else { return }
            // The rows as they read now: an edit while the pages were read is taken into account.
            let rows = self.libraryFiles(atPaths: files.map(\.path))
            let plan: (writes: [String], records: [String]) = run.date.map {
                Self.folderDatingPlan($0, files: rows, evidence: evidence)
            } ?? (writes: Self.folderUndatingPlan(files: rows, evidence: evidence), records: [])
            guard !plan.writes.isEmpty else { return }
            // The container edit's catalog read may still be running; the answer is written only after it.
            for _ in 0..<50 where self.containerEditSaving { try? await Task.sleep(for: .milliseconds(100)) }
            guard tree.path == self.containerTree?.path, !self.containerEditSaving else { return }
            self.folderDatingOffer = FolderDatingOffer(date: run.date, treePath: tree.path, directory: dir,
                                                       editedName: name, paths: plan.writes, recorded: plan.records,
                                                       evidence: evidence, window: window)
        }
    }

    /// "Date N Documents": the evidence records first, then the tags, one ledger group (one Undo). The folder's date is
    /// read again first: one undone, removed or changed since the offer dates nothing. A file whose date changed since
    /// the offer, so that it no longer takes the folder's, is left alone, and its record taken back.
    func applyFolderDating(_ offer: FolderDatingOffer) {
        folderDatingOffer = nil
        itemFieldEditPath = nil   // a refusal is shown in the Checks whatever is selected
        guard let tree = containerTree, tree.path == offer.treePath else { return }
        guard let record = offer.date?.record else {
            if offer.date == nil { applyFolderUndating(offer, tree: tree.url) }
            return
        }
        let names = offer.recorded.map { ($0 as NSString).lastPathComponent }
        let editedName = offer.editedName
        runContainerEdit(done: "", action: "Folder Date", undo: nil, document: .itemFields, {
            // The same date, and the run still holds every file: one that left it no longer takes this date.
            guard let run = Self.folderDateRun(tree: tree.url, components: offer.directory, editedName: editedName),
                  run.date == offer.date, Set(names).isSubset(of: run.names) else {
                throw FolderDateChanged()
            }
            let directory = try Self.containerDirectoryURL(tree.url, offer.directory)
            _ = try Self.editItemFields(at: directory) { fields in
                var fields = fields
                for name in names { fields.setDateRecord(record, for: name) }
                return fields
            }
            return nil
        }, onSaved: { [weak self] in self?.writeFolderDates(offer) })
    }

    /// "Update N Documents" for a folder that no longer gives a date: its date is read again first (one set since dates
    /// nothing here), then the tags, one ledger group. The records are left: they no longer describe the files, and
    /// they speak for them again if Undo puts the folder's date back.
    private func applyFolderUndating(_ offer: FolderDatingOffer, tree: URL) {
        let names = offer.paths.map { ($0 as NSString).lastPathComponent }
        runContainerEdit(done: "", action: "Folder Date", undo: nil, document: .itemFields, {
            guard let run = Self.folderDateRun(tree: tree, components: offer.directory, editedName: offer.editedName),
                  run.date == nil, Set(names).isSubset(of: run.names) else { throw FolderDateChanged() }
            return nil
        }, onSaved: { [weak self] in self?.writeFolderDates(offer) })
    }

    /// The tag half of `applyFolderDating`, on the main thread as every other tag edit.
    private func writeFolderDates(_ offer: FolderDatingOffer) {
        let reverified = reverifyCacheRows(libraryFiles(atPaths: offer.paths))
        var verified: [TagWriteResult] = []
        var changed = 0
        var failures = reverified.rejected
        var dated: Set<String> = []
        AuditLedger.withContext(group: UUID()) {   // §12: one ledger group, as it is one undo
            for f in reverified.files {
                let e = offer.evidence[f.path]
                let evidence = FolderDateRecord.evidence(e?.record, page: e?.page, tags: f.tags)
                guard f.itemType == nil else { continue }
                let delta: TagDelta?
                if let date = offer.date {
                    delta = date.dates(f.tags, evidence: evidence) ? date.delta(given: f.tags) : nil
                } else {
                    delta = ContainerFolderDate.folderGave(f.tags, evidence: evidence)
                        ? ContainerFolderDate.undatingDelta(given: f.tags, page: e?.page) : nil
                }
                guard let delta, !delta.isEmpty else { continue }
                do {
                    let r = try TagWriter.apply(delta, to: f.url, expecting: f.liveIdentity())
                    verified.append(r)
                    dated.insert(f.path)
                    if !r.isNoOp { changed += 1 }
                } catch { failures += 1 }
            }
        }
        library.applyVerifiedWrites(verified)
        refreshUndoHistory()
        // A record only for a file that now carries the folder's date: one skipped or refused here may later carry the
        // same date by other means (its own text, a Finder edit), and the record would then speak for it.
        let undated = offer.paths.filter { !dated.contains($0) }.map { ($0 as NSString).lastPathComponent }
        if !undated.isEmpty, let tree = containerTree, tree.path == offer.treePath, let record = offer.date?.record {
            let directory = offer.directory
            Task.detached(priority: .utility) {
                guard let url = try? Self.containerDirectoryURL(tree.url, directory) else { return }
                _ = try? Self.editItemFields(at: url) { fields in
                    var fields = fields
                    for name in undated where fields.dateRecord(for: name) == record { fields.setDateRecord(nil, for: name) }
                    return fields
                }
            }
        }
        let n = "\(changed) document\(changed == 1 ? "" : "s")"
        let done = offer.date.map { "Dated \(n) \($0.inheritedDate?.date.display ?? $0.text) from the folder" }
            ?? "Took the folder's date from \(n)"
        statusMessage = done + (failures > 0 ? "; \(failures) could not update." : ".")
        announce(statusMessage)
    }

    // MARK: Off the main thread, and pure

    /// The run whose date was saved at `editedName`, if its date is confirmed and dates documents: every file on disk
    /// the same folder run is live at, in the folder's order. Read only.
    nonisolated static func folderDatingRun(tree: URL, components: [String], editedName: String) -> FolderDatingRun? {
        guard let run = folderDateRun(tree: tree, components: components, editedName: editedName),
              run.date != nil else { return nil }
        return run
    }

    /// The run at `editedName` after a date edit, whatever its date (W49.reader-folder-date-undo): its confirmed date
    /// where that dates documents, else nil, and every file on disk the same run is live at (with no run live there,
    /// every file no run is live at), in the folder's order. Nil when the container file cannot be read. Read only.
    nonisolated static func folderDateRun(tree: URL, components: [String], editedName: String) -> FolderDatingRun? {
        guard let directory = try? containerDirectoryURL(tree, components) else { return nil }
        let runs: [ContainerRun]
        switch ContainerFileStore.load(directory: directory) {
        case .missing: runs = []
        case let .loaded(file, _): runs = file.runs
        default: return nil
        }
        guard let all = try? fileNames(in: directory) else { return nil }
        let date = ContainerFolderDate.confirmed(at: editedName, in: runs).flatMap { $0.inherited == nil ? nil : $0 }
        let run = ContainerResolver.liveRuns(at: editedName, in: runs).last
        let names = all.filter { name in
            let live = ContainerResolver.liveRuns(at: name, in: runs).last
            return live?.level == run?.level && live?.start == run?.start
        }.sorted(by: ContainerOrder.precedes)
        return FolderDatingRun(date: date, directory: directory, names: names)
    }

    /// Each file's page-2 date evidence and classification, and the Reader's records beside them. A placeholder that
    /// is not on disk is never read (its evidence is unknown, so a date it carries stands). Read only.
    nonisolated static func folderDatingEvidence(_ files: [(path: String, url: URL, dataless: Bool)],
                                                 directory: URL) -> [String: FolderDatingEvidence] {
        let records = ContainerFileStore.loadItemFields(directory: directory).document
        var out: [String: FolderDatingEvidence] = [:]
        for f in files {
            var e = FolderDatingEvidence(record: records?.dateRecord(for: f.url.lastPathComponent))
            if !f.dataless, let doc = PDFDocument(url: f.url), !doc.isLocked {
                let headers = PDFHeaderParser.textPageHeaders(doc).compactMap { $0 }
                e.page = headers.lazy.compactMap(\.dateEvidence).first
                // SPEC/tag-format.md: the verified Classification values for a box or folder photo.
                e.containerPhoto = headers.contains { $0.classification == "Box" || $0.classification == "Folder" }
            }
            out[f.path] = e
        }
        return out
    }

    /// Which files carry a date the folder gave (`ContainerFolderDate.folderGave`), for a folder that no longer gives
    /// one; those whose tags change. A file with no evidence read, a box or folder photo, or one that is not a PDF is
    /// left alone.
    nonisolated static func folderUndatingPlan(files: [ArchiveFile], evidence: [String: FolderDatingEvidence]) -> [String] {
        files.filter { f in
            guard f.url.pathExtension.lowercased() == "pdf", f.itemType == nil, let e = evidence[f.path],
                  !e.containerPhoto,
                  ContainerFolderDate.folderGave(f.tags, evidence: FolderDateRecord.evidence(e.record, page: e.page,
                                                                                             tags: f.tags)) else {
                return false
            }
            return !ContainerFolderDate.undatingDelta(given: f.tags, page: e.page).isEmpty
        }.map(\.path)
    }

    /// Which files take `date`: `records` every one that does, `writes` those whose tags change. A file with no
    /// evidence read (not in `evidence`), a box or folder photo, or one that is not a PDF takes nothing.
    nonisolated static func folderDatingPlan(_ date: ContainerFolderDate, files: [ArchiveFile],
                                             evidence: [String: FolderDatingEvidence])
        -> (writes: [String], records: [String]) {
        var writes: [String] = [], records: [String] = []
        for f in files where f.url.pathExtension.lowercased() == "pdf" && f.itemType == nil {
            guard let e = evidence[f.path], !e.containerPhoto,
                  date.dates(f.tags, evidence: FolderDateRecord.evidence(e.record, page: e.page, tags: f.tags)),
                  let delta = date.delta(given: f.tags) else { continue }
            records.append(f.path)
            if !delta.isEmpty { writes.append(f.path) }
        }
        return (writes, records)
    }
}
