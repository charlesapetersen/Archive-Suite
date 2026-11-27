import Foundation
import ArchiveCore

// MARK: - The suite's tag change log, the Reader's side (W40.tag-rename-suite, Tier-2; SPEC/tag-format.md invariant 8)
//
// A rename, merge or remove here is recorded in `<granted root>/.archivesuite/tag-changes.json` (ArchiveCore
// `TagChangeLog`), one entry per tag, kept against the change's ledger group (in catalogue mode its journal operation),
// so Notes can offer it for its notes; that change's Undo marks its entries withdrawn and its Redo clears that. Changes recorded by the other apps are offered in Tags ▸ Tag Changes from Other Apps…, applied through the
// ordinary `renameTag` (TagWriter, one Undo) or skipped. The log is only ever written through `TagChangeLog`.

/// Another app's change waiting in the Reader, or (`isWithdrawal`) one applied here that its app has since undone.
struct ReaderTagChangeOffer: Identifiable, Equatable, Sendable {
    let change: TagChange
    /// Files carrying `change.from` when it was read.
    let count: Int
    let isWithdrawal: Bool
    var id: UUID { change.id }

    var summary: String {
        let app = change.appName.prefix(1).uppercased() + change.appName.dropFirst()
        if isWithdrawal, change.isRemoval {
            return "\(app) undid removing “\(change.from)”. Your files stay without it; add it again where you want it."
        }
        if change.isRemoval {
            let when = change.at.formatted(date: .abbreviated, time: .omitted)
            return "\(app) removed “\(change.from)” from its items on \(when). "
                + "\(count) file\(count == 1 ? "" : "s") carr\(count == 1 ? "ies" : "y") it."
        }
        if isWithdrawal {
            return "\(app) undid renaming “\(change.from)” to “\(change.to)”. Your files keep “\(change.to)”; "
                + "use Rename Tag… to change them back."
        }
        let when = change.at.formatted(date: .abbreviated, time: .omitted)
        return "\(app) renamed “\(change.from)” to “\(change.to)” on \(when). "
            + "\(count) file\(count == 1 ? "" : "s") carr\(count == 1 ? "ies" : "y") “\(change.from)”."
    }
}

extension NavigationModel {
    /// The granted root and its durable marker guid, where the log lives; nil without a durable identity.
    var tagChangeRoot: (guid: UUID, url: URL)? {
        guard let root = rootStore.root, let marker = rootStore.rootMarker else { return nil }
        return (marker.guid, root)
    }

    private var tagChangeDefaults: UserDefaults {
        tagChangeDefaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// Each recorded change's ledger group (or journal operation) and its entries' ids, oldest first: "group id id…".
    private static let recordedGroupsKey = "tagChangeRecordedEntries"
    private static let reversalsKey = "tagChangeReversals"
    private static let rememberedLimit = 500

    /// Records a rename made here so the other apps can offer it; its id is `id`, the rename's ledger group.
    func recordTagChange(id: UUID, from old: String, to new: String) {
        recordTagChanges(group: id, [TagChange(id: id, app: TagChangeLog.reader, from: old, to: new)])
    }

    /// Records changes made here so the other apps can offer them, kept against `group`, the ledger group (or catalogue
    /// journal operation) whose Undo withdraws them. A lone entry takes the group's id. Off the main actor; a failure
    /// only adds to the status line (the files are already changed).
    func recordTagChanges(group: UUID, _ changes: [TagChange]) {
        var kept = changes.filter(TagChangeLog.isRecordable)
        guard let root = tagChangeRoot, !kept.isEmpty else { return }
        if kept.count == 1, kept[0].id != group {
            let c = kept[0]
            kept[0] = TagChange(id: group, at: c.at, app: c.app, from: c.from, to: c.to)
        }
        rememberRecordedGroup(group, entries: kept.map(\.id))
        let url = root.url
        let entries = kept
        Self.logQueue.async { [weak self] in
            do { try TagChangeLog.record(entries, root: url) } catch {
                let failure = Self.describeTagChangeFailure(error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.statusMessage += " Notes was not told: \(failure)."
                        self.announce(self.statusMessage)
                    }
                }
            }
        }
    }

    /// Every write of the log, in the order the Reader made them: a record, its Undo's withdrawal and its Redo's.
    nonisolated private static let logQueue = DispatchQueue(label: "ArchiveReader.TagChangeLog", qos: .utility)

    /// After an Undo or Redo of ledger group `group` (run as `reversal`): when that group is, or reverses, a recorded
    /// rename, its entry is withdrawn (Undo) or restored (Redo).
    func tagChangeReversed(group: UUID, by reversal: UUID, redo: Bool) {
        var reversals = tagChangeDefaults.dictionary(forKey: Self.reversalsKey) as? [String: String] ?? [:]
        let original = reversals[group.uuidString] ?? group.uuidString
        guard let ids = recordedEntries(original), let root = tagChangeRoot else { return }
        reversals[reversal.uuidString] = original
        if reversals.count > Self.rememberedLimit {
            // Oldest first is unknown in a dictionary; drop arbitrary ones but never the one just added.
            for key in reversals.keys.filter({ $0 != reversal.uuidString }).prefix(reversals.count - Self.rememberedLimit) {
                reversals.removeValue(forKey: key)
            }
        }
        tagChangeDefaults.set(reversals, forKey: Self.reversalsKey)
        let url = root.url
        Self.logQueue.async { try? TagChangeLog.setWithdrawn(ids, !redo, root: url) }
    }

    /// The entries recorded for `group`, or nil when it recorded none.
    private func recordedEntries(_ group: String) -> Set<UUID>? {
        for line in (tagChangeDefaults.stringArray(forKey: Self.recordedGroupsKey) ?? []).reversed() {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.first == group else { continue }
            let ids = Set(parts.dropFirst().compactMap(UUID.init(uuidString:)))
            return ids.isEmpty ? nil : ids
        }
        return nil
    }

    private func rememberRecordedGroup(_ group: UUID, entries: [UUID]) {
        var list = tagChangeDefaults.stringArray(forKey: Self.recordedGroupsKey) ?? []
        list.append(([group] + entries).map(\.uuidString).joined(separator: " "))
        if list.count > Self.rememberedLimit { list.removeFirst(list.count - Self.rememberedLimit) }
        tagChangeDefaults.set(list, forKey: Self.recordedGroupsKey)
    }

    private func handledTagChanges(_ guid: UUID) -> TagChangeHandled {
        TagChangeHandled(rootGUID: guid.uuidString, suiteName: tagChangeDefaultsSuite)
    }

    private func appliedTagChanges(_ guid: UUID) -> TagChangeHandled {
        TagChangeHandled.applied(rootGUID: guid.uuidString, suiteName: tagChangeDefaultsSuite)
    }

    /// Reads the log and works out what to offer.
    func refreshTagChangeInbox() async {
        guard let root = tagChangeRoot else { tagChangeOffers = []; return }
        let url = root.url
        // After the queued writes, so a just-recorded change is read back as the Reader's own.
        let load = await withCheckedContinuation { done in
            Self.logQueue.async { done.resume(returning: TagChangeLog.load(root: url)) }
        }
        guard tagChangeRoot?.guid == root.guid, let doc = load.document else { tagChangeOffers = []; return }
        let carried = Set(library.files.flatMap(\.subjects).map(tagKey))
        let box = TagChangeLog.inbox(doc, app: TagChangeLog.reader, handled: handledTagChanges(root.guid).ids,
                                     applied: appliedTagChanges(root.guid).ids, carried: carried)
        handledTagChanges(root.guid).insert(box.settled)
        tagChangeOffers = box.offers.map { ReaderTagChangeOffer(change: $0, count: affectedFileCount(forTag: $0.from),
                                                                isWithdrawal: false) }
            + box.withdrawals.map { ReaderTagChangeOffer(change: $0, count: 0, isWithdrawal: true) }
    }

    /// Reads the log after a scan settles and shows the sheet when it holds an offer not shown this session.
    func offerNewTagChanges() async {
        guard !tagChangeRefreshing else { return }   // a settle during a refresh adds nothing to it
        tagChangeRefreshing = true
        await refreshTagChangeInbox()
        tagChangeRefreshing = false
        let fresh = Set(tagChangeOffers.map(\.id)).subtracting(tagChangesPresented)
        // Never over another sheet: macOS would not show it and the flag would stay set.
        guard !fresh.isEmpty, !showingTagChanges, !showingSaveDialog
        else { return }
        tagChangesPresented.formUnion(fresh)
        showingTagChanges = true
    }

    /// Applies another app's change to the Reader's files through the ordinary rename (TagWriter, one Undo), or a
    /// remove through the Tags window's writer, not recorded again.
    func applyTagChange(_ offer: ReaderTagChangeOffer) {
        guard !offer.isWithdrawal else { dismissTagChange(offer); return }
        guard let root = tagChangeRoot, !refuseWhileTagBatchRuns() else { return }
        let guid = root.guid
        let settle: @MainActor (Int, Int) -> Void = { [weak self] changed, failed in
            guard let self else { return }
            if changed > 0 { appliedTagChanges(guid).insert([offer.id]) }
            guard failed == 0 else { return }
            handledTagChanges(guid).insert([offer.id])
            tagChangeOffers.removeAll { $0.id == offer.id }
        }
        if offer.change.isRemoval {
            guard let plan = tagInventory(carrying: offer.change.from).removePlan([offer.change.from]) else {
                settle(0, 0)   // nothing carries it any more
                return
            }
            Task { [weak self] in
                guard let self else { return }
                let outcome = await applyTagPlan(plan, recording: false)
                settle(outcome.changed, outcome.failed)
            }
            return
        }
        // A file that could not be changed still carries the old tag: the change stays offered for it.
        renameTag(from: offer.change.from, to: offer.change.to, recording: false) { changed, failed in
            settle(changed, failed)
        }
    }

    /// Skip (or, for a withdrawal, OK): not offered again.
    func dismissTagChange(_ offer: ReaderTagChangeOffer) {
        if let root = tagChangeRoot {
            handledTagChanges(root.guid).insert([offer.id])
            if offer.isWithdrawal { appliedTagChanges(root.guid).remove([offer.id]) }
        }
        tagChangeOffers.removeAll { $0.id == offer.id }
    }

    nonisolated static func describeTagChangeFailure(_ error: Error) -> String {
        switch error as? ContainerWriteError {
        case .io(_, let e) where e == EACCES || e == EPERM || e == EROFS: "the archive folder is read-only"
        case .busy: "another app was writing the record"
        case .refusedExisting(let why): "its change record is \(why)"
        case .notOrdinary: "its change record is a link"
        default: error.localizedDescription
        }
    }
}
