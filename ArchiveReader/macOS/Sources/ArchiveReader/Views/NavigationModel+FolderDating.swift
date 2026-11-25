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
//
// W49.reader-folder-date-undo-fu: each record keeps the date the folder replaced (or none), and taking the folder's
// dates away puts that back, not page 2's. Taking them away retires the records it undated, and Undo or Redo Tag Change
// of a date change retires or revives the record as the file loses or regains its date
// (`folderDateRecordsFollow`), so a date typed again in Finder is the user's. An Undo or Redo of the Container section's
// own date edit offers as the edit did (`offerFolderDatingAfterUndo`).

/// The offer made after a folder date is confirmed: which documents it would date. One offer may cover several folder
/// runs, in one folder or several (W49.reader-set-selection-date-offer: a date set for a selection makes a run for each
/// stretch of neighbours); it is answered once, as one ledger group.
struct FolderDatingOffer: Identifiable, Equatable {
    /// One folder run the offer dates.
    struct Part: Equatable {
        /// The run's folder date; nil takes away the dates the folder gave (W49.reader-folder-date-undo).
        let date: ContainerFolderDate?
        /// The folder below the tree's root, and a file of the run (the one the date was saved at).
        let directory: [String]
        let editedName: String
        /// The files whose tags change, in the folder's order.
        let paths: [String]
        /// Every file that takes the date (those already reading so too): each gets the evidence record.
        let recorded: [String]
    }

    let id = UUID()
    /// In the folders' order. A part dates its run's documents, or takes away the dates its folder gave; one offer may
    /// do both (an Undo across runs that dated and did not date before).
    let parts: [Part]
    let treePath: String
    /// What each file's date rested on when the offer was made.
    let evidence: [String: FolderDatingEvidence]
    /// The date each recorded file had before the folder's (`ContainerFolderDate.replacedDate`); absent for none.
    var replaced: [String: FolderDateRecord.Replaced] = [:]
    /// The window the edit was made in, whose Inspector asks; nil asks in any.
    let window: ObjectIdentifier?

    /// The first part's folder date; nil takes the dates away. Each part writes its own.
    var date: ContainerFolderDate? { parts.first?.date }
    var paths: [String] { parts.flatMap(\.paths) }
    var recorded: [String] { parts.flatMap(\.recorded) }

    /// The folders the parts are in, each once, in order.
    var directories: [[String]] {
        var seen: Set<[String]> = []
        return parts.map(\.directory).filter { seen.insert($0).inserted }
    }

    private var dating: [Part] { parts.filter { $0.date != nil } }
    private var undating: [Part] { parts.filter { $0.date == nil } }

    private static func documents(_ n: Int) -> String { "\(n) document\(n == 1 ? "" : "s")" }
    private var count: String { Self.documents(paths.count) }

    var title: String {
        let folders = directories
        let place = folders.count == 1 ? "“\(folders.first?.last ?? "the folder")”" : "\(folders.count) folders"
        let from = folders.count == 1 ? "the folder" : "their folders"
        if dating.isEmpty {
            return "Take the folder\(folders.count == 1 ? "'s" : "s'") date from \(count) in \(place)?"
        }
        return undating.isEmpty ? "Date \(count) in \(place) from \(from)?" : "Update \(count) in \(place) from \(from)?"
    }

    /// The folders, for an offer in several: each by its path below the tree's root, at most 10 named.
    private var folderList: String {
        let folders = directories
        guard folders.count > 1 else { return "" }
        let named = folders.prefix(10).map { "“\($0.isEmpty ? "the top folder" : $0.joined(separator: "/"))”" }
        let more = folders.count > named.count ? ", and \(folders.count - named.count) more" : ""
        return "The folders: " + named.joined(separator: ", ") + more + ". "
    }

    var message: String {
        let undo = "Edit ▸ Undo Tag Change (⌘Z) takes it back."
        let several = directories.count > 1
        let place = several ? "them" : "it"
        func them(_ n: Int, _ one: String, _ many: String) -> String {
            n == 1 ? "1 document in \(place) \(one)" : "\(n) documents in \(place) \(many)"
        }
        let undated = undating.flatMap(\.paths).count
        guard !dating.isEmpty else {
            return (several ? "The folders no longer give a date. " : "The folder no longer gives a date. ") + folderList
                + "\(them(undated, "was", "were")) dated from the folder's date; each goes back to the "
                + "stamp's or estimate's date it had, or to no date. Dates you changed or checked since, and dates "
                + "from a document's own text or page image, are left as they are. " + undo
        }
        // Each run's date, once each: a selection sets one; an Undo across runs may put back several.
        var seen: Set<String> = []
        let dates = dating.compactMap(\.date).filter { seen.insert($0.text).inserted }
        let named = dates.prefix(10).map { "“\($0.text)”" }.joined(separator: ", ")
            + (dates.count > 10 ? ", and \(dates.count - 10) more" : "")
        let each = dates.count == 1
            ? "each would be dated " + (dates[0].inheritedDate.map { $0.date.display + ($0.uncertain ? ", marked uncertain" : "") } ?? "")
            : "each would take its own folder's date"
        let lead = several || dates.count > 1 ? "The folders are dated \(named). " : "The folder is dated \(named). "
        let dated = "\(them(dating.flatMap(\.paths).count, "has", "have")) no date, an estimated date "
            + "or an earlier date from the folder. With this change, \(each). "
        guard undated > 0 else {
            return lead + folderList + dated + "Dates read from a document's text, page image or stamp, checked dates "
                + "and the folder photo are left as they are. " + undo
        }
        return lead + folderList + dated + "\(Self.documents(undated)) dated from a folder that no longer gives a date "
            + "\(undated == 1 ? "goes" : "go") back to the stamp's or estimate's date \(undated == 1 ? "it" : "each") had, "
            + "or to no date. Dates you changed or checked since, dates read from a document's text, page image or stamp, "
            + "and the folder photo are left as they are. " + undo
    }

    var confirmTitle: String {
        let n = "\(paths.count) Document\(paths.count == 1 ? "" : "s")"
        return undating.isEmpty ? "Date \(n)" : "Update \(n)"
    }

    /// The status line after the answer: `changed` documents written.
    func done(_ changed: Int) -> String {
        let n = Self.documents(changed)
        let several = directories.count > 1
        guard !dating.isEmpty else { return "Took the folder\(several ? "s'" : "'s") date from \(n)" }
        guard undating.isEmpty, let date else { return "Updated \(n) from their folders" }
        return "Dated \(n) \(date.inheritedDate?.date.display ?? date.text) from the folder\(several ? "s" : "")"
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

/// The folder runs a date set for a selection is in (W49.reader-set-selection-date-offer): for each folder, the first
/// selected file of each run, and whether a confirmed folder date dated documents there before (`FolderDateBefore`).
/// Set off the main thread by the edit's work and read after it finished.
final class FolderDateSelection: @unchecked Sendable {
    struct Run: Equatable, Sendable {
        let name: String
        let datedBefore: Bool
    }

    /// By the folder's directory path; a retried edit replaces what its first try noted.
    var runs: [String: [Run]] = [:]
    /// The folder below the tree's root, by the same path, for the edit that knows it.
    var components: [String: [String]] = [:]
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
        offerFolderDating(runs: [(path, datedBefore)], window: window)
    }

    /// `offerFolderDating(at:)` for several runs at once (W49.reader-set-selection-date-offer): each named by a file of
    /// it, with whether it dated before. One offer covers every run that would change a document; a run named twice
    /// counts once.
    func offerFolderDating(runs edited: [(path: String, datedBefore: Bool)], window: ObjectIdentifier?) {
        guard !library.usesCatalogue, let tree = containerTree else { return }
        var byFolder: [[String]: [(name: String, datedBefore: Bool)]] = [:]
        var order: [[String]] = []
        for e in edited {
            guard let (dir, name) = ContainerCatalog.split(e.path, under: tree.path) else { continue }
            if byFolder[dir] == nil { order.append(dir) }
            byFolder[dir, default: []].append((name, e.datedBefore))
        }
        guard !order.isEmpty else { return }
        let (asked, folders) = (byFolder, order)
        Task { [weak self] in
            // Each folder's container file is read once, however many of its runs are named.
            let found = await Task.detached(priority: .userInitiated) {
                folders.map { dir -> [(dir: [String], name: String, run: FolderDatingRun)] in
                    let named = asked[dir] ?? []
                    guard let runs = Self.folderDateRuns(tree: tree.url, components: dir,
                                                         editedNames: named.map(\.name)) else { return [] }
                    var seen: Set<String> = []
                    return zip(named, runs).compactMap { n, run in
                        guard run.date != nil || n.datedBefore, seen.insert(run.names.first ?? n.name).inserted
                        else { return nil }
                        return (dir, n.name, run)
                    }
                }.flatMap { $0 }
            }.value
            guard let self, !found.isEmpty, tree.path == self.containerTree?.path else { return }
            let root = tree.path.hasSuffix("/") ? String(tree.path.dropLast()) : tree.path
            let reads = found.map { f -> (files: [String], directory: URL, reads: [(path: String, url: URL, dataless: Bool)]) in
                let base = ([root] + f.dir).joined(separator: "/")
                let files = self.libraryFiles(atPaths: f.run.names.map { base + "/" + $0 })
                    .filter { $0.url.pathExtension.lowercased() == "pdf" && $0.itemType == nil }
                return (files.map(\.path), f.run.directory, files.map { ($0.path, $0.url, $0.isDataless) })
            }
            let evidence = await Task.detached(priority: .userInitiated) {
                reads.reduce(into: [String: FolderDatingEvidence]()) { all, r in
                    all.merge(Self.folderDatingEvidence(r.reads, directory: r.directory)) { a, _ in a }
                }
            }.value
            guard tree.path == self.containerTree?.path else { return }
            var parts: [FolderDatingOffer.Part] = []
            var replaced: [String: FolderDateRecord.Replaced] = [:]
            for (f, r) in zip(found, reads) {
                // The rows as they read now: an edit while the pages were read is taken into account.
                let rows = self.libraryFiles(atPaths: r.files)
                let plan = f.run.date.map { Self.folderDatingPlan($0, files: rows, evidence: evidence) }
                    ?? (writes: Self.folderUndatingPlan(files: rows, evidence: evidence), records: [], replaced: [:])
                guard !plan.writes.isEmpty else { continue }
                parts.append(.init(date: f.run.date, directory: f.dir, editedName: f.name, paths: plan.writes,
                                   recorded: plan.records))
                replaced.merge(plan.replaced) { a, _ in a }
            }
            guard !parts.isEmpty else { return }
            // The container edit's catalog read may still be running; the answer is written only after it.
            for _ in 0..<50 where self.containerEditSaving { try? await Task.sleep(for: .milliseconds(100)) }
            guard tree.path == self.containerTree?.path, !self.containerEditSaving else { return }
            self.folderDatingOffer = FolderDatingOffer(parts: parts, treePath: tree.path, evidence: evidence,
                                                       replaced: replaced, window: window)
        }
    }

    /// Whether every part's run still holds the date it was offered with and every file it names: one that left it no
    /// longer takes this date. Each folder's container file is read once. Read only.
    nonisolated private static func partsStand(_ parts: [FolderDatingOffer.Part], tree: URL,
                                               names: (FolderDatingOffer.Part) -> [String]) -> Bool {
        var byFolder: [[String]: [FolderDatingOffer.Part]] = [:]
        for part in parts { byFolder[part.directory, default: []].append(part) }
        return byFolder.allSatisfy { dir, parts in
            guard let runs = folderDateRuns(tree: tree, components: dir, editedNames: parts.map(\.editedName))
            else { return false }
            return zip(parts, runs).allSatisfy { part, run in
                run.date == part.date && Set(names(part)).isSubset(of: run.names)
            }
        }
    }

    /// "Date N Documents": the evidence records first, then the tags, one ledger group (one Undo). Each run's folder
    /// date is read again first: one undone, removed or changed since the offer changes nothing, in any of its folders.
    /// The records of several folders are written all or nothing (`commitAll`). A file whose date changed since the
    /// offer, so that it no longer takes the folder's, is left alone, and its record taken back. A part for a folder
    /// that no longer gives a date writes no record: its records are retired after the tags (`writeFolderDates`), and
    /// Undo Tag Change revives them as it puts the folder's date back (`folderDateRecordsFollow`).
    func applyFolderDating(_ offer: FolderDatingOffer) {
        folderDatingOffer = nil
        itemFieldEditPath = nil   // a refusal is shown in the Checks whatever is selected
        guard !library.usesCatalogue, let tree = containerTree, tree.path == offer.treePath else { return }
        // Each folder's records, every part of it together.
        var records: [[String]: [(name: String, record: FolderDateRecord)]] = [:]
        for part in offer.parts {
            guard let date = part.date else { continue }
            guard let plain = date.record else { return }
            for path in part.recorded {
                records[part.directory, default: []].append(((path as NSString).lastPathComponent,
                                                             date.record(replacing: offer.replaced[path]) ?? plain))
            }
        }
        let folders = records.sorted { $0.key.joined(separator: "/") < $1.key.joined(separator: "/") }
        runContainerEdit(done: "", action: "Folder Date", undo: nil, document: .itemFields, {
            guard Self.partsStand(offer.parts, tree: tree.url, names: { part in
                (part.date == nil ? part.paths : part.recorded).map { ($0 as NSString).lastPathComponent }
            }) else { throw FolderDateChanged() }
            let prepared = try folders.compactMap { dir, named in
                try Self.prepareItemFieldEdit(at: try Self.containerDirectoryURL(tree.url, dir)) { fields in
                    var fields = fields
                    for (name, record) in named { fields.setDateRecord(record, for: name) }
                    return fields
                }
            }
            _ = try Self.commitAll(prepared)
            return nil
        }, onSaved: { [weak self] in self?.writeFolderDates(offer) })
    }

    /// The tag half of `applyFolderDating`, on the main thread as every other tag edit.
    private func writeFolderDates(_ offer: FolderDatingOffer) {
        guard !library.usesCatalogue else { return }
        var partOf: [String: FolderDatingOffer.Part] = [:]
        for part in offer.parts { for path in part.paths { partOf[path] = part } }
        let reverified = reverifyCacheRows(libraryFiles(atPaths: offer.paths))
        var verified: [TagWriteResult] = []
        var changed = 0
        var failures = reverified.rejected
        var dated: Set<String> = []
        let group = UUID()
        let planned = reverified.files.compactMap { f -> (f: ArchiveFile, delta: TagDelta)? in
            let e = offer.evidence[f.path]
            let evidence = FolderDateRecord.evidence(e?.record, page: e?.page, tags: f.tags)
            guard f.itemType == nil, let part = partOf[f.path] else { return nil }
            let delta: TagDelta?
            if let date = part.date {
                // A file whose date changed since the offer, so that its record would keep another date as the
                // one replaced, is left alone too (W49.reader-folder-date-undo-fu).
                let same = ContainerFolderDate.replacedDate(f.tags, evidence: evidence, record: e?.record)
                    == offer.replaced[f.path]
                delta = same && date.dates(f.tags, evidence: evidence) ? date.delta(given: f.tags) : nil
            } else {
                delta = ContainerFolderDate.folderGave(f.tags, evidence: evidence)
                    ? ContainerFolderDate.undatingDelta(given: f.tags, page: e?.page, record: e?.record) : nil
            }
            guard let delta, !delta.isEmpty else { return nil }
            return (f, delta)
        }
        // §12: one ledger group, as it is one undo; its intent lists the files it expects to change.
        AuditLedger.withContext(group: group, files: planned.map(\.f.url)) {
            for (f, delta) in planned {
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
        // Taking the dates away retires, by this group, the records it undated (W49.reader-folder-date-undo-fu).
        // Each folder's records in one edit.
        var taken: [[String]: [(name: String, record: FolderDateRecord)]] = [:]
        var retired: [[String]: [(name: String, record: FolderDateRecord)]] = [:]
        for part in offer.parts {
            for path in part.paths {
                let name = (path as NSString).lastPathComponent
                if let date = part.date {
                    guard !dated.contains(path), let record = date.record(replacing: offer.replaced[path]) else { continue }
                    taken[part.directory, default: []].append((name, record))
                } else if dated.contains(path), let record = offer.evidence[path]?.record {
                    retired[part.directory, default: []].append((name, record))
                }
            }
        }
        if !taken.isEmpty || !retired.isEmpty, let tree = containerTree, tree.path == offer.treePath {
            let folders = Set(taken.keys).union(retired.keys)
                .sorted { $0.joined(separator: "/") < $1.joined(separator: "/") }
            let (takenByFolder, retiredByFolder) = (taken, retired)
            Self.folderDateRecordQueue.async {
                for directory in folders {
                    guard let url = try? Self.containerDirectoryURL(tree.url, directory) else { continue }
                    Self.editFolderDateRecords(at: url) { fields in
                        for (name, record) in takenByFolder[directory] ?? [] where fields.dateRecord(for: name) == record {
                            fields.setDateRecord(nil, for: name)
                        }
                        for (name, record) in retiredByFolder[directory] ?? []
                        where fields.dateRecord(for: name) == record {
                            var retiring = record
                            retiring.retiredBy = group.uuidString
                            fields.setDateRecord(retiring, for: name)
                        }
                    }
                }
            }
        }
        let done = offer.done(changed)
        statusMessage = done + (failures > 0 ? "; \(failures) could not update." : ".")
        announce(statusMessage)
    }

    /// After Undo or Redo of a Container-section edit (W49.reader-folder-date-undo-fu): where it changed a folder run's
    /// confirmed date, offers as the edit itself does, for the first file of each run whose date changed, in every
    /// folder the edit wrote (W49.reader-set-selection-date-offer: a selection's edit makes several). `step` is the
    /// reverse just registered: each restore's `restore` is what the folder held before, `written` what it holds now.
    func offerFolderDatingAfterUndo(_ step: ContainerUndoStep, window: ObjectIdentifier) {
        guard let tree = containerTree else { return }
        let root = tree.url.resolvingSymlinksInPath().pathComponents
        let base = tree.path.hasSuffix("/") ? String(tree.path.dropLast()) : tree.path
        var runs: [(path: String, datedBefore: Bool)] = []
        for r in step.restores {
            guard case let .containers(before) = r.restore, case let .containers(after) = r.written else { continue }
            let folder = r.folder.pathComponents
            guard folder.starts(with: root), let names = try? Self.fileNames(in: r.folder) else { continue }
            let prefix = [base] + folder.dropFirst(root.count)
            for (name, datedBefore) in Self.datedRunsChanged(names, before: before.runs, after: after.runs) {
                runs.append(((prefix + [name]).joined(separator: "/"), datedBefore))
            }
        }
        if !runs.isEmpty { offerFolderDating(runs: runs, window: window) }
    }

    /// The first of `names` in each run of `after` where a file's confirmed folder date differs from `before`'s, and
    /// whether a date that dates documents was confirmed there before. One pass over each (`lastLiveRuns`). A date is
    /// compared with its text, so the collection's numeric date order (`folderDateRuns`) cannot change the answer.
    nonisolated static func datedRunsChanged(_ names: [String], before: [ContainerRun],
                                             after: [ContainerRun]) -> [(name: String, datedBefore: Bool)] {
        let sorted = names.sorted(by: ContainerOrder.precedes)
        let was = lastLiveRuns(sorted, in: before), now = lastLiveRuns(sorted, in: after)
        var out: [(name: String, datedBefore: Bool)] = []
        var last: String?   // the run of the last file taken: its level and start, or "" for none live
        for (i, name) in sorted.enumerated() {
            let old = was[i].flatMap { ContainerFolderDate.confirmed(at: name, in: [$0]) }
            guard old != now[i].flatMap({ ContainerFolderDate.confirmed(at: name, in: [$0]) }) else { continue }
            let key = now[i].map { "\($0.level.rawValue)/\($0.start)" } ?? ""
            guard key != last else { continue }
            last = key
            out.append((name, old?.inherited != nil))
        }
        return out
    }

    /// The deepest run live at each of `sortedNames` (in `ContainerOrder`), as `ContainerResolver.liveRuns(at:in:).last`
    /// reads it, in one pass: `runs` is in `ContainerFile.normalised` order.
    nonisolated static func lastLiveRuns(_ sortedNames: [String], in runs: [ContainerRun]) -> [ContainerRun?] {
        var live: [ContainerRun] = []
        var j = 0
        return sortedNames.map { name in
            while j < runs.count, ContainerOrder.atOrBefore(runs[j].start, name) {
                let run = runs[j]
                live.removeAll { $0.level >= run.level }
                live.append(run)
                j += 1
            }
            return live.last
        }
    }

    /// After Undo or Redo Tag Change (W49.reader-folder-date-undo-fu) of the ledger group `reversed`, run as the group
    /// `reversal`: a record that `reversed` retired, whose file the reversal left carrying its date, is live again; a
    /// live one whose file it left without that date is retired by `reversal`, so its own reversal revives it. A date
    /// the user later types in Finder, or that another change puts back, is the user's. Only results that changed a
    /// file's date are looked at; a file outside the container tree has no record.
    func folderDateRecordsFollow(_ results: [TagWriteResult], reversed: UUID, reversal: UUID) {
        guard let tree = containerTree else { return }
        var byFolder: [[String]: [String: DocumentTags]] = [:]
        for r in results {
            let before = DocumentTags.parse(raw: r.before, labelNumber: r.beforeLabel)
            let after = DocumentTags.parse(raw: r.after, labelNumber: r.afterLabel)
            guard ContainerFolderDate.evidenceGave(before) != ContainerFolderDate.evidenceGave(after)
                    || before.year != after.year || before.decade != after.decade,
                  let (dir, name) = ContainerCatalog.split(r.url.path, under: tree.path) else { continue }
            byFolder[dir, default: [:]][name] = after
        }
        guard !byFolder.isEmpty else { return }
        let folders = byFolder
        Self.folderDateRecordQueue.async {
            for (dir, files) in folders {
                guard let url = try? Self.containerDirectoryURL(tree.url, dir) else { continue }
                Self.editFolderDateRecords(at: url) { fields in
                    for (name, tags) in files {
                        guard var record = fields.dateRecord(for: name) else { continue }
                        let carries = record.carries(tags)
                        if record.retiredBy == reversed.uuidString, carries {
                            record.retiredBy = nil
                        } else if !record.retired, !carries {
                            record.retiredBy = reversal.uuidString
                        } else { continue }
                        fields.setDateRecord(record, for: name)
                    }
                }
            }
        }
    }

    /// After the library watcher saw files' tags change outside the Reader (W49.reader-folder-date-undo-fu2): a record
    /// whose file's date changed (in Finder or another app) is retired by `externalRetirement`, which no Undo reverses;
    /// one already retired by a ledger group is too, so that group's reversal cannot revive it over a date typed since.
    /// So a date removed in Finder and typed there again is the user's, as is one typed over the folder's. A change
    /// that leaves the date as it was (a Read mark, a subject) leaves the record alone.
    func folderDateRecordsSeeExternal(_ changes: [ArchiveLibrary.ExternalTagChange]) {
        guard let tree = containerTree else { return }
        var byFolder: [[String]: Set<String>] = [:]
        for c in changes where Self.dateDiffers(c.old, c.new) {
            guard let (dir, name) = ContainerCatalog.split(c.url.path, under: tree.path) else { continue }
            byFolder[dir, default: []].insert(name)
        }
        guard !byFolder.isEmpty else { return }
        let folders = byFolder
        Self.folderDateRecordQueue.async {
            for (dir, names) in folders {
                guard let url = try? Self.containerDirectoryURL(tree.url, dir) else { continue }
                // Most folders keep no records; their item fields are not rewritten.
                guard let fields = ContainerFileStore.loadItemFields(directory: url).document,
                      names.contains(where: { Self.retiresExternally(fields.dateRecord(for: $0)) }) else { continue }
                Self.editFolderDateRecords(at: url) { fields in
                    for name in names {
                        guard var record = fields.dateRecord(for: name), Self.retiresExternally(record) else { continue }
                        record.retiredBy = FolderDateRecord.externalRetirement
                        fields.setDateRecord(record, for: name)
                    }
                }
            }
        }
    }

    nonisolated private static func retiresExternally(_ record: FolderDateRecord?) -> Bool {
        record.map { $0.retiredBy != FolderDateRecord.externalRetirement } ?? false
    }

    /// Whether two tag sets give the file a different date, as `FolderDateRecord.carries` reads it: its Year, Decade,
    /// Month, Day, `Date Uncertain`, or a date tag carried twice (a covering letter's aside).
    nonisolated static func dateDiffers(_ a: DocumentTags, _ b: DocumentTags) -> Bool {
        func twice(_ t: DocumentTags) -> [DateAmbiguity] { t.dateAmbiguities.filter { $0.facet != .sentWith } }
        return a.year != b.year || a.decade != b.decade || a.month != b.month || a.day != b.day
            || a.dateUncertain != b.dateUncertain || twice(a) != twice(b)
    }

    /// The record edits made after a tag write, one at a time and in the order made, so a retirement and the Undo
    /// that revives it land in that order.
    nonisolated static let folderDateRecordQueue = DispatchQueue(label: "ArchiveReader.folderDateRecords", qos: .utility)

    /// One record edit on `folderDateRecordQueue`, tried again where another writer (a Checks edit) changed the file
    /// between its read and its write; a document it cannot read or write is left as it is.
    nonisolated static func editFolderDateRecords(at directory: URL, _ change: (inout UserItemFields) -> Void) {
        for _ in 0..<3 {
            do {
                _ = try editItemFields(at: directory) { fields in
                    var fields = fields
                    change(&fields)
                    return fields
                }
                return
            } catch ContainerWriteError.changedSinceRead, ContainerWriteError.busy {
                Thread.sleep(forTimeInterval: 0.05)
            } catch { return }
        }
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
        folderDateRuns(tree: tree, components: components, editedNames: [editedName])?.first
    }

    /// `folderDateRun` for several files of one folder at once, in their order (W49.reader-set-selection-date-offer):
    /// the container file and the folder are read once, and each file's run found in one pass, so a selection that made
    /// thousands of runs costs about as much as one. A numeric date reads in the collection's order, as Process Files
    /// and Live Capture read it (`numericDatesDayFirst`, W49.reader-folder-date-day-first): the record of the
    /// collection holding the folder, within the tree. Read only.
    nonisolated static func folderDateRuns(tree: URL, components: [String], editedNames: [String]) -> [FolderDatingRun]? {
        guard let directory = try? containerDirectoryURL(tree, components) else { return nil }
        let runs: [ContainerRun]
        switch ContainerFileStore.load(directory: directory) {
        case .missing: runs = []
        case let .loaded(file, _): runs = file.runs
        default: return nil
        }
        guard let all = try? fileNames(in: directory) else { return nil }
        let names = Array(Set(all).union(editedNames)).sorted(by: ContainerOrder.precedes)
        let live = lastLiveRuns(names, in: runs)
        func key(_ run: ContainerRun?) -> String { run.map { "\($0.level.rawValue)/\($0.start)" } ?? "" }
        var keyOf: [String: String] = [:], liveAt: [String: ContainerRun] = [:], byRun: [String: [String]] = [:]
        let onDisk = Set(all)
        let dayFirst = CollectionSettingsRecord.numericDatesDayFirst(directory: directory, within: tree)
        for (name, run) in zip(names, live) {
            keyOf[name] = key(run)
            liveAt[name] = run
            if onDisk.contains(name) { byRun[key(run), default: []].append(name) }   // in the folder's order
        }
        return editedNames.map { edited in
            let run = liveAt[edited]
            let date = ContainerFolderDate.$dayFirst.withValue(dayFirst) {
                run.flatMap { ContainerFolderDate.confirmed(at: edited, in: [$0]) }
            }.flatMap { $0.inherited == nil ? nil : $0 }
            return FolderDatingRun(date: date, directory: directory, names: byRun[keyOf[edited] ?? ""] ?? [])
        }
    }

    /// Each file's page-2 date evidence and classification, and the Reader's records beside them. A placeholder that
    /// is not on disk is never read (its evidence is unknown, so a date it carries stands). Read only.
    nonisolated static func folderDatingEvidence(_ files: [(path: String, url: URL, dataless: Bool)],
                                                 directory: URL) -> [String: FolderDatingEvidence] {
        folderDateRecordQueue.sync {}   // a retirement or revival still pending lands first
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
            return !ContainerFolderDate.undatingDelta(given: f.tags, page: e.page, record: e.record).isEmpty
        }.map(\.path)
    }

    /// Which files take `date`: `records` every one that does, `writes` those whose tags change, and `replaced` the date
    /// each recorded file had before the folder's. A file with no evidence read (not in `evidence`), a box or folder
    /// photo, or one that is not a PDF takes nothing.
    nonisolated static func folderDatingPlan(_ date: ContainerFolderDate, files: [ArchiveFile],
                                             evidence: [String: FolderDatingEvidence])
        -> (writes: [String], records: [String], replaced: [String: FolderDateRecord.Replaced]) {
        var writes: [String] = [], records: [String] = [], replaced: [String: FolderDateRecord.Replaced] = [:]
        for f in files where f.url.pathExtension.lowercased() == "pdf" && f.itemType == nil {
            guard let e = evidence[f.path], !e.containerPhoto else { continue }
            let rests = FolderDateRecord.evidence(e.record, page: e.page, tags: f.tags)
            guard date.dates(f.tags, evidence: rests), let delta = date.delta(given: f.tags) else { continue }
            records.append(f.path)
            replaced[f.path] = ContainerFolderDate.replacedDate(f.tags, evidence: rests, record: e.record)
            if !delta.isEmpty { writes.append(f.path) }
        }
        return (writes, records, replaced)
    }
}
