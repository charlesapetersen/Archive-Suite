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

/// The offer made after a folder date is confirmed: which documents it would date.
struct FolderDatingOffer: Identifiable, Equatable {
    let id = UUID()
    let date: ContainerFolderDate
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

    var title: String {
        "Date \(paths.count) document\(paths.count == 1 ? "" : "s") in “\(directory.last ?? "the folder")” from the folder?"
    }

    var message: String {
        let shown = date.inheritedDate.map { $0.date.display + ($0.uncertain ? ", marked uncertain" : "") } ?? ""
        let them = paths.count == 1 ? "1 document in it has" : "\(paths.count) documents in it have"
        return "The folder is dated “\(date.text)”. \(them) no date of its own, or one only estimated or taken from a "
            + "stamp; each would be dated \(shown). Dates read from a document's text or page image, checked dates "
            + "and the folder photo are left as they are. Tags ▸ Undo Tag Change (⌘Z) takes it back."
    }

    var confirmTitle: String { "Date \(paths.count) Document\(paths.count == 1 ? "" : "s")" }
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
    var errorDescription: String? { "the folder's date changed since it was offered, so no document was dated." }
}

/// A folder run whose confirmed date can date documents: the date, the folder on disk and the run's files.
struct FolderDatingRun: Sendable {
    let date: ContainerFolderDate
    let directory: URL
    let names: [String]
}

extension NavigationModel {
    /// After the folder date at `path` was saved: works out which documents it dates and, if any, offers it.
    func offerFolderDating(at path: String, window: ObjectIdentifier?) {
        guard let tree = containerTree, let (dir, name) = ContainerCatalog.split(path, under: tree.path) else { return }
        Task { [weak self] in
            let run = await Task.detached(priority: .userInitiated) {
                Self.folderDatingRun(tree: tree.url, components: dir, editedName: name)
            }.value
            guard let self, let run, tree.path == self.containerTree?.path else { return }
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
            let plan = Self.folderDatingPlan(run.date, files: self.libraryFiles(atPaths: files.map(\.path)),
                                             evidence: evidence)
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
        guard let tree = containerTree, tree.path == offer.treePath, let record = offer.date.record else { return }
        let names = offer.recorded.map { ($0 as NSString).lastPathComponent }
        runContainerEdit(done: "", action: "Folder Date", undo: nil, document: .itemFields, {
            guard let run = Self.folderDatingRun(tree: tree.url, components: offer.directory,
                                                 editedName: offer.editedName), run.date == offer.date else {
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
                guard f.itemType == nil, offer.date.dates(f.tags, evidence: evidence),
                      let delta = offer.date.delta(given: f.tags), !delta.isEmpty else { continue }
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
        if !undated.isEmpty, let tree = containerTree, tree.path == offer.treePath, let record = offer.date.record {
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
        let shown = offer.date.inheritedDate?.date.display ?? offer.date.text
        statusMessage = "Dated \(changed) document\(changed == 1 ? "" : "s") \(shown) from the folder"
            + (failures > 0 ? "; \(failures) could not update." : ".")
        announce(statusMessage)
    }

    // MARK: Off the main thread, and pure

    /// The run whose date was saved at `editedName`, if its date is confirmed and dates documents: every file on disk
    /// the same folder run is live at, in the folder's order. Read only.
    nonisolated static func folderDatingRun(tree: URL, components: [String], editedName: String) -> FolderDatingRun? {
        guard let directory = try? containerDirectoryURL(tree, components),
              let runs = ContainerFileStore.load(directory: directory).document?.runs,
              let date = ContainerFolderDate.confirmed(at: editedName, in: runs), date.inherited != nil,
              let run = ContainerResolver.liveRuns(at: editedName, in: runs).last,
              let all = try? fileNames(in: directory) else { return nil }
        let names = all.filter { name in
            guard let live = ContainerResolver.liveRuns(at: name, in: runs).last else { return false }
            return live.level == run.level && live.start == run.start
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
