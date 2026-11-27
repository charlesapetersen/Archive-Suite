import Foundation
import ArchiveCore

// MARK: - Rename or merge a subject across every note and extract (W40.tag-rename-suite, Tier-2)
//
// Front matter first, then the Finder mirror, one note at a time through `rewriteSubjects` (one atomic `withItem`
// each, as the tag bar's edits). A rename into an existing subject merges into it. The change is then recorded in
// each reachable archive's tag change log (`ArchiveCore.TagChangeLog`, SPEC/tag-format.md invariant 8) so the
// Reader can offer it for its files; Notes writes nothing else in the archive. Undo puts back only what the rename
// changed on each note, so an edit made since to another subject survives. Design: execution-plans/tag-rename-suite.md.

/// What one rename, merge or remove did: each changed note's subjects before, the notes it could not save, and the log
/// entries it recorded (withdrawn by its Undo).
struct SubjectRenameOutcome: Sendable, Equatable {
    /// The subjects renamed, as asked, and the subject they became, title-cased; empty for a remove.
    let from: [String]
    let to: String
    var isRemoval: Bool { to.isEmpty }
    /// Each note the rename saved, with its subjects just before.
    var changed: [UUID: [String]] = [:]
    var failed: [UUID] = []
    /// Notes whose front matter was saved but whose Finder mirror failed (reported; retried by the next tag edit).
    var unmirrored: [UUID] = []
    var recorded: [UUID] = []
    /// Why the change could not be recorded for the other apps, if it could not.
    var notRecorded: String?
}

extension NotesModel {
    /// Subjects in use with how many notes and extracts carry each, by tag identity, title-cased as Notes shows and
    /// writes them (a hand-edited file may hold another case).
    var subjectCounts: [String: Int] {
        Dictionary(tagCounts(allItems.map { $0.managedTags.map(NotesTagVocabulary.titleCased) })
            .map { ($0.tag, $0.count) }, uniquingKeysWith: +)
    }

    /// The notes and extracts carrying `subject` (by `tagKey`, so a hand-typed lower-case spelling counts).
    func notesCarrying(_ subject: String) -> [UUID] {
        let key = tagKey(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        return allItems.filter { $0.managedTags.contains { tagKey($0) == key } }.map(\.id)
    }

    /// The subject a rename to `typed` writes: an existing subject's spelling when it is one, else `typed`, title-cased.
    func subjectSpelling(for typed: String) -> String? {
        guard let typed = NotesTagVocabulary.normalizedSubjects([typed]).first else { return nil }
        let key = tagKey(typed)
        return subjectCounts.keys.first { tagKey($0) == key }.flatMap { NotesTagVocabulary.normalizedSubjects([$0]).first }
            ?? typed
    }

    /// Renames every subject in `olds` to `typed` on every note and extract carrying one (by `tagKey`); into an
    /// existing subject it merges; an empty `typed` removes them (a remove another app recorded, schema 2). `only`
    /// restricts it to those notes (a Redo). Records the change in each reachable archive unless `recording` is false
    /// (applying another app's change, which is already in the log). Nil when there was nothing to do.
    func renameSubjects(_ olds: [String], to typed: String, only: Set<UUID>? = nil,
                        recording: Bool = true) async -> SubjectRenameOutcome? {
        let removing = typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let target = removing ? "" : subjectSpelling(for: typed) else { return nil }
        let targetKey = tagKey(target)
        let oldKeys = Set(olds.map { tagKey($0.trimmingCharacters(in: .whitespacesAndNewlines)) }).subtracting([""])
        // Only facet-free subjects: a rating or date facet in front matter is a subject too, but the suite's own
        // tokens are never renamed (invariant 8).
        guard !oldKeys.isEmpty, removing || !keepsExactCase(target),
              olds.allSatisfy({ !keepsExactCase($0) }) else { return nil }
        let holders = allItems.filter { item in
            (only?.contains(item.id) ?? true) && item.managedTags.contains { oldKeys.contains(tagKey($0)) }
        }.map(\.id)
        guard !holders.isEmpty else { return nil }
        var outcome = SubjectRenameOutcome(from: olds, to: target)
        for id in holders {
            let result = await rewriteSubjects(of: id, "rename the tag") { tags in
                Self.renamed(tags, from: oldKeys, to: target, targetKey: targetKey)
            }
            guard let result else { outcome.failed.append(id); continue }
            guard result.before != result.after else { continue }
            outcome.changed[id] = result.before
            if !result.mirrored { outcome.unmirrored.append(id) }
        }
        await reloadItems()
        if recording, !outcome.changed.isEmpty {
            let entries = olds.filter { tagKey($0) != targetKey }.map {
                TagChange(app: TagChangeLog.notes, from: $0, to: target)
            }.filter(TagChangeLog.isRecordable)
            let (recorded, why) = await recordTagChanges(entries)
            outcome.recorded = recorded
            outcome.notRecorded = why
        }
        statusMessage = Self.renameStatus(outcome)
        return outcome
    }

    /// Undo of `outcome`: on each note it changed, `to` goes again where the rename added it and the subjects it
    /// removed come back, on the note's latest front matter. Marks its log entries withdrawn. Returns the notes it
    /// put back, for the Redo.
    func undoRename(_ outcome: SubjectRenameOutcome) async -> Set<UUID> {
        let targetKey = tagKey(outcome.to)
        let oldKeys = Set(outcome.from.map(tagKey))
        var restored = Set<UUID>()
        var failed = 0
        for (id, before) in outcome.changed {
            let hadTarget = before.contains { tagKey($0) == targetKey }
            let removed = before.filter { oldKeys.contains(tagKey($0)) && tagKey($0) != targetKey }
            let result = await rewriteSubjects(of: id, "undo the tag rename") { tags in
                var out = hadTarget ? tags : tags.filter { tagKey($0) != targetKey }
                for r in removed where !out.contains(where: { tagKey($0) == tagKey(r) }) { out.append(r) }
                return out
            }
            if result != nil { restored.insert(id) } else { failed += 1 }
        }
        await reloadItems()
        await withdrawTagChanges(Set(outcome.recorded), true)
        let what = outcome.isRemoval ? "removing “\(outcome.from.joined(separator: "”, “"))”" : "renaming to “\(outcome.to)”"
        statusMessage = failed == 0 ? "Undid \(what)."
            : "Undid \(what); \(failed) note\(failed == 1 ? "" : "s") could not be saved."
        return restored
    }

    /// A note's subjects with every one keyed in `from` replaced by `to` (once, where the first stood), or as they
    /// were when none is. An empty `to` removes them.
    nonisolated static func renamed(_ tags: [String], from keys: Set<String>, to target: String,
                                    targetKey: String) -> [String] {
        guard tags.contains(where: { keys.contains(tagKey($0)) }) else { return tags }
        if target.isEmpty { return tags.filter { !keys.contains(tagKey($0)) } }
        var out: [String] = []
        var placed = false
        for tag in tags {
            let key = tagKey(tag)
            if keys.contains(key) || key == targetKey {
                if !placed { out.append(target); placed = true }
            } else {
                out.append(tag)
            }
        }
        return out
    }

    private static func renameStatus(_ o: SubjectRenameOutcome) -> String {
        let n = o.changed.count
        var s = o.isRemoval
            ? "Removed “\(o.from.joined(separator: "”, “"))” from \(n) note\(n == 1 ? "" : "s")"
            : "Renamed to “\(o.to)” on \(n) note\(n == 1 ? "" : "s")"
        s += o.failed.isEmpty ? "." : "; \(o.failed.count) could not be saved."
        if !o.unmirrored.isEmpty { s += " \(o.unmirrored.count) kept the old Finder tag; edit a tag there to retry." }
        if let why = o.notRecorded { s += " The other apps were not told: \(why)" }
        return s
    }

    // MARK: The archives' change logs

    /// Appends `entries` to the log of every archive Notes can reach. Returns what was recorded, and why it was not
    /// where it was not (nil when every reachable archive took it, or when there are none: then nobody reads it).
    func recordTagChanges(_ entries: [TagChange]) async -> (recorded: [UUID], notRecorded: String?) {
        guard !entries.isEmpty else { return ([], nil) }
        let roots = archiveRoots()
        guard !roots.isEmpty else { return ([], nil) }
        var failures: [String] = []
        for root in roots {
            let url = root.url
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Self.withScope(url) { try TagChangeLog.record(entries, root: url) }
                }.value
            } catch {
                failures.append("\(url.lastPathComponent): \(Self.describe(error))")
            }
        }
        return (entries.map(\.id), failures.isEmpty ? nil : failures.joined(separator: "; ") + ".")
    }

    func withdrawTagChanges(_ ids: Set<UUID>, _ withdrawn: Bool) async {
        guard !ids.isEmpty else { return }
        for root in archiveRoots() {
            let url = root.url
            try? await Task.detached(priority: .userInitiated) {
                try Self.withScope(url) { try TagChangeLog.setWithdrawn(ids, withdrawn, root: url) }
            }.value
        }
    }

    /// Runs `body` holding its own security scope on `url`, so a preview giving up its scope on the same archive
    /// meanwhile cannot cut the log's read or write short.
    nonisolated static func withScope<T>(_ url: URL, _ body: () throws -> T) rethrows -> T {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try body()
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error as? ContainerWriteError {
        case .io(_, let e) where e == EACCES || e == EPERM || e == EROFS: "the archive folder is read-only"
        case .busy: "another app was writing the record"
        case .refusedExisting(let why): "its change record is \(why)"
        case .notOrdinary: "its change record is a link"
        default: error.localizedDescription
        }
    }
}

// MARK: - Other apps' changes (the inbox)

/// One change another app recorded, waiting in Notes for Apply or Skip, or (`isWithdrawal`) one Notes applied that
/// its app has since undone, shown once. `roots` is every archive whose log holds it.
struct TagChangeOffer: Identifiable, Sendable, Equatable {
    let change: TagChange
    var roots: [UUID]
    /// Notes and extracts carrying `change.from` when it was read.
    var count: Int
    let isWithdrawal: Bool
    var id: UUID { change.id }

    var summary: String {
        let when = change.at.formatted(date: .abbreviated, time: .omitted)
        if isWithdrawal, change.isRemoval {
            return "\(change.appName.capitalizedFirst) undid removing “\(change.from)”. Your notes stay without it; "
                + "add it again where you want it."
        }
        if change.isRemoval {
            return "\(change.appName.capitalizedFirst) removed “\(change.from)” from its items on \(when). "
                + "\(count) note\(count == 1 ? "" : "s") carr\(count == 1 ? "ies" : "y") it."
        }
        if isWithdrawal {
            return "\(change.appName.capitalizedFirst) undid renaming “\(change.from)” to “\(change.to)”. Your notes keep "
                + "“\(NotesTagVocabulary.titleCased(change.to))”; use Rename Tag… to change them back."
        }
        let verb = change.isRespelling ? "re-spelled" : "renamed"
        return "\(change.appName.capitalizedFirst) \(verb) “\(change.from)” to “\(change.to)” on \(when). "
            + "\(count) note\(count == 1 ? "" : "s") carr\(count == 1 ? "ies" : "y") “\(change.from)”."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension NotesModel {
    /// Each archive's lists, kept per library too: a change skipped in one library is still offered in another.
    private func listKey(_ root: UUID) -> String {
        root.uuidString + "." + (tagChangeLibraryKey ?? libraryGUID?.uuidString ?? "no-library")
    }

    private func handled(_ root: UUID) -> TagChangeHandled {
        TagChangeHandled(rootGUID: listKey(root), suiteName: tagChangeDefaultsSuite)
    }

    private func applied(_ root: UUID) -> TagChangeHandled {
        TagChangeHandled.applied(rootGUID: listKey(root), suiteName: tagChangeDefaultsSuite)
    }

    /// Reads every reachable archive's log and works out what to offer (`TagChangeLog.inbox`). Only an entry that can
    /// never apply here is settled without asking; one nothing carries yet, or withdrawn, is passed over for now.
    func refreshTagChangeInbox() async {
        // Only over a settled library: its subjects decide what is offered.
        guard isLibrarySettled else { tagChangeOffers = []; return }
        var offers: [TagChangeOffer] = []
        let carried = Set(allItems.flatMap(\.managedTags).map(tagKey))
        for root in archiveRoots() {
            let url = root.url
            let load = await Task.detached(priority: .utility) { Self.withScope(url) { TagChangeLog.load(root: url) } }.value
            guard let doc = load.document else { continue }
            let box = TagChangeLog.inbox(doc, app: TagChangeLog.notes, handled: handled(root.guid).ids,
                                         applied: applied(root.guid).ids, carried: carried, ignoresRespelling: true)
            handled(root.guid).insert(box.settled)
            for (change, withdrawal) in box.offers.map({ ($0, false) }) + box.withdrawals.map({ ($0, true) }) {
                if let i = offers.firstIndex(where: { $0.id == change.id }) {
                    offers[i].roots.append(root.guid)
                } else {
                    offers.append(TagChangeOffer(change: change, roots: [root.guid],
                                                 count: notesCarrying(change.from).count, isWithdrawal: withdrawal))
                }
            }
        }
        tagChangeOffers = offers
    }

    /// Applies another app's change to Notes' own notes, as Rename Tag… would, without recording it again.
    @discardableResult
    func applyTagChange(_ offer: TagChangeOffer) async -> SubjectRenameOutcome? {
        guard !offer.isWithdrawal else { dismissTagChange(offer); return nil }
        let outcome = await renameSubjects([offer.change.from], to: offer.change.to, recording: false)
        // A note that could not be saved still carries the old tag: the change stays offered for it.
        let settled = outcome?.failed.isEmpty != false
        for root in offer.roots {
            if outcome?.changed.isEmpty == false { applied(root).insert([offer.id]) }
            if settled { handled(root).insert([offer.id]) }
        }
        if settled { tagChangeOffers.removeAll { $0.id == offer.id } }
        return outcome
    }

    /// Skip (or, for a withdrawal, OK): marks it handled so it is not offered again.
    func dismissTagChange(_ offer: TagChangeOffer) {
        for root in offer.roots {
            handled(root).insert([offer.id])
            if offer.isWithdrawal { applied(root).remove([offer.id]) }
        }
        tagChangeOffers.removeAll { $0.id == offer.id }
    }
}
