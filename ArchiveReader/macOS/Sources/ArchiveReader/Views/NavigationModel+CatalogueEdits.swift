import ArchiveCore
import Foundation

extension NavigationModel {
    /// An observed selection can outlive a fresh scan while the user is typing. Keep its edit base
    /// so a conflicting change to that same field is refused at save.
    func applyCatalogueDocumentField(_ field: CatalogueEdit.DocumentField, _ change: CatalogueEdit.Change,
                                     paths: [String]? = nil, physicalPageIndex: Int? = nil,
                                     observed: [ItemFacts]? = nil) {
        editCatalogue(title: "Catalogue Change", paths: paths, physicalPageIndex: physicalPageIndex,
                      observed: observed) { facts in
            facts.catalogueDocumentEdit { id, _ in CatalogueEdit(.document(id, field), change) }
        }
    }

    /// Returns false, with any reason in `statusMessage`, when no save started; `completed` follows a save's report.
    @discardableResult
    func applyCatalogueFileField(_ field: CatalogueEdit.FileField, _ change: CatalogueEdit.Change,
                                 paths: [String]? = nil, observed: [ItemFacts]? = nil,
                                 completed: ((Set<String>) -> Void)? = nil) -> Bool {
        editCatalogue(title: "Catalogue Change", paths: paths, observed: observed, completed: completed) { facts in
            (try? facts.file.get()).map { ($0, CatalogueEdit(.file(field), change)) }
        }
    }

    /// Apply a token addition or removal to each owner's own list, including a mixed selection.
    /// An edit to a different owner's list never clears or replaces names that were left untouched.
    func updateCatalogueNames(_ field: CatalogueEdit.DocumentField, paths: [String]? = nil,
                              physicalPageIndex: Int? = nil, observed: [ItemFacts]? = nil,
                              update: ([String]) -> [String]) {
        editCatalogue(title: "Catalogue Change", paths: paths, physicalPageIndex: physicalPageIndex,
                      observed: observed) { facts in
            facts.catalogueDocumentEdit { id, fields in
                let names: CatalogueRecord.Field<[String]>?
                switch field {
                case .byline: names = fields.byline
                case .senders: names = fields.senders
                case .recipients: names = fields.recipients
                case .sendingPlaces: names = fields.sendingPlaces
                case .recipientPlaces: names = fields.recipientPlaces
                case .subjects: names = fields.subjects
                default: return nil
                }
                return CatalogueEdit(.document(id, field), .set(.names(update(Self.value(names) ?? []))))
            }
        }
    }

    func applyCatalogueRotation(path: String, pageIndex: Int, turns: Int, observed: ItemFacts,
                                completed: ((Set<String>) -> Void)? = nil) {
        editCatalogue(title: "Rotation", paths: [path], physicalPageIndex: pageIndex, observed: [observed],
                      completed: completed) { facts in
            guard let file = try? facts.file.get(), let page = facts.page else { return nil }
            let change: CatalogueEdit.Change = turns == 0 ? .clear : .set(.rotation(turns * 90))
            return (file, CatalogueEdit(.pageViewRotation(page.id), change))
        }
    }

    func applyCatalogueTagEdit(_ op: TagEditOp, paths: [String]?, physicalPageIndex: Int?) {
        if case .setQuality(let quality) = op {
            applyCatalogueFileField(.quality, quality.map { .set(.rating($0)) } ?? .clear, paths: paths)
            return
        }
        editCatalogue(title: "Catalogue Change", paths: paths, physicalPageIndex: physicalPageIndex) { facts in
            facts.catalogueDocumentEdit { id, fields in
                Self.catalogueTagEdit(op, id: id, fields: fields)
            }
        }
    }

    func applyCatalogueItemEdit(_ field: CheckableField, _ edit: ItemFieldEdit, paths: [String],
                                physicalPageIndex: Int? = nil) {
        guard let field = Self.catalogueField(field) else { return }
        let change: CatalogueEdit.Change
        switch edit {
        case .none: change = .clear
        case .remove: return // An explicit clear or an Undo represents the catalogue actions for this field.
        case .set(let typed):
            let value = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                change = .clear
            } else {
                switch field {
                case .byline, .senders, .recipients, .sendingPlaces, .recipientPlaces:
                    change = .set(.names(value.split(separator: ";").map {
                        $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    }.filter { !$0.isEmpty }))
                case .publicationDate:
                    guard case .date(let date, _) = InspectorDateEntry.read(value) else {
                        reportCatalogue("Enter a publication date such as “March 1958”.")
                        return
                    }
                    change = .set(.date(.init(date: date, uncertain: false)))
                default: change = .set(.text(value))
                }
            }
        }
        applyCatalogueDocumentField(field, change, paths: paths, physicalPageIndex: physicalPageIndex)
    }

    /// Use the same owner resolution and duplicate handling for inline and Inspector subject edits.
    /// `operationID` is the journal operation's id, given when a change recorded for the other apps must follow its
    /// Undo and Redo (W40.tag-window-reader: the entry's id is the operation's, as a file rename's is its ledger group).
    /// Given `documents`, every catalogue document of each PDF whose subjects it accepts is edited, in the one
    /// operation, rather than the one document the PDF resolves to (the Tags window, W40.tag-window-reader-multidoc).
    @discardableResult
    func editCatalogueSubjects(paths: [String], title: String = "Subjects Change", operationID: UUID? = nil,
                               documents: (([String]) -> Bool)? = nil,
                               completed: ((Set<String>) -> Void)? = nil,
                               _ update: ([String]) -> [String]) -> Bool {
        let carries = documents.map { accepts in
            { (facts: ItemFacts) in accepts(Self.value((try? facts.document.get())?.document.fields?.subjects) ?? []) }
        }
        return editCatalogue(title: title, paths: paths, operationID: operationID, documents: carries,
                      completed: completed) { facts in
            facts.catalogueDocumentEdit { id, fields in
                CatalogueEdit(.document(id, .subjects), .set(.names(update(Self.value(fields.subjects) ?? []))))
            }
        }
    }

    @discardableResult
    func markCatalogue(_ state: ReadState, paths: [String]? = nil,
                       completed: ((Set<String>) -> Void)? = nil) -> Bool {
        editCatalogue(title: "Read State Change", paths: paths, completed: completed) { facts in
            (try? facts.file.get()).map {
                ($0, CatalogueEdit(.file(.readState), .set(.text(state.rawValue.lowercased()))))
            }
        }
    }

    func refreshCatalogueEditHistory() {
        let rootID = library.usesCatalogue ? catalogueReader?.rootInstanceID : nil
        guard rootID != catalogueHistoryRootID else { return }
        catalogueHistoryRootID = rootID
        catalogueHistory = .init()
        catalogueEditFeedback = nil
        catalogueEditFailures = []
        guard let rootID else { return }
        Task { [weak self] in
            let heads = await Task.detached(priority: .utility) { try? CatalogueEditJournal(rootID: rootID).read() }.value
            guard let self, self.catalogueHistoryRootID == rootID, !self.catalogueEditSaving else { return }
            if let heads {
                self.catalogueHistory = heads
                if heads.uncertainCount > 0 {
                    self.catalogueEditFeedback = "Undo history is incomplete for \(heads.uncertainCount) catalogue record(s)."
                }
            } else {
                self.catalogueEditFeedback = "Catalogue edit history could not be read."
            }
        }
    }

    func reverseCatalogueEdit(redo: Bool) {
        guard !catalogueEditSaving, let reader = catalogueReader, library.usesCatalogue else { return }
        let run: @Sendable (CatalogueEditJournal.Session) throws -> CatalogueActionResult = { journal in
            guard let group = journal.history.next(redo: redo) else { return .init() }
            let operation = CatalogueEditJournal.Operation(
                direction: redo ? .redo(group.operation.id) : .undo(group.operation.id), title: group.operation.title
            )
            // These references target already resolved owning records directly. Their physical
            // identities and unchanged content generations are verified again by reverse().
            let selected = group.inverses.map(\.occurrence.relativePath)
            let scope = reader.snapshot(.init(relativePDFPaths: [], isComplete: false), including: selected)
            let writer = CatalogueWriter(reader: reader)
            var result = CatalogueActionResult()
            result.reversal = .init(group: group.operation.id, by: operation.id, redo: redo)
            for inverse in group.inverses.reversed() {
                try result.attempt(operation, occurrence: inverse.occurrence, journal: journal) {
                    let base = try scope.facts(at: inverse.occurrence.relativePath).file.get()
                    return try writer.reverse(inverse, basedOn: base)
                }
            }
            return result
        }
        runCatalogueAction(reader: reader, verb: redo ? "Redid" : "Undid", run)
    }

    @discardableResult
    private func editCatalogue(title: String, paths: [String]?, physicalPageIndex: Int? = nil,
                               observed: [ItemFacts]? = nil, operationID: UUID? = nil,
                               documents: ((ItemFacts) -> Bool)? = nil,
                               completed: ((Set<String>) -> Void)? = nil,
                               edit: (ItemFacts) -> (ItemFacts.FileFacts, CatalogueEdit)?) -> Bool {
        editCatalogue(title: title, paths: paths, physicalPageIndex: physicalPageIndex, observed: observed,
                      operationID: operationID, documents: documents, completed: completed,
                      edits: { facts in edit(facts).map { [$0] } ?? [] })
    }

    /// Several edits for one selection, saved as one operation (the Finder mirror's Import,
    /// W49.storage-finder-reader-mirror). A selection with no edit is refused.
    @discardableResult
    func editCatalogue(title: String, paths: [String]?, physicalPageIndex: Int? = nil,
                       observed: [ItemFacts]? = nil, operationID: UUID? = nil,
                       documents: ((ItemFacts) -> Bool)? = nil,
                       completed: ((Set<String>) -> Void)? = nil,
                       edits: (ItemFacts) -> [(ItemFacts.FileFacts, CatalogueEdit)]) -> Bool {
        guard !catalogueEditSaving else {
            reportCatalogue("Wait for the current catalogue change to finish, then try again.")
            return false
        }
        guard library.usesCatalogue, let reader = catalogueReader else {
            reportCatalogue("Catalogue records are still being checked. Try again after the scan.")
            return false
        }
        let rows = tagTargets(paths)
        let requested = paths?.count ?? rows.count
        guard requested > 0 else { return false }
        let current: [ItemFacts]
        var refused: Int
        if let documents {
            // Each document a PDF counts, at its first page as the row lists it, read again now; a PDF with none
            // that `documents` accepts is not changed (W40.tag-window-reader-multidoc).
            let perRow = rows.map { row in
                (row.catalogueDocuments.isEmpty ? [row.catalogueFacts].compactMap { $0 } : row.catalogueDocuments)
                    .compactMap { listed in catalogueFacts(for: row, physicalPageIndex: listed.page?.physicalIndex) }
                    .filter(documents)
            }
            current = perRow.flatMap { $0 }
            refused = max(0, requested - perRow.count { !$0.isEmpty })
        } else {
            current = rows.compactMap { catalogueFacts(for: $0, physicalPageIndex: physicalPageIndex) }
            refused = 0
        }
        // By page as well when every document is edited, as one PDF then gives several selections.
        func key(_ facts: ItemFacts, _ file: ItemFacts.FileFacts) -> SelectionKey {
            SelectionKey(occurrence: file.pair.occurrence, page: documents == nil ? nil : facts.page?.id)
        }
        let selected = Dictionary(current.compactMap { facts -> (SelectionKey, ItemFacts)? in
            (try? facts.file.get()).map { (key(facts, $0), facts) }
        }, uniquingKeysWith: { first, _ in first })
        let selection = observed ?? current
        if documents == nil { refused = max(0, requested - selection.count) }
        // With every document edited, the PDFs a refused document belongs to: none of them is reported as saved.
        var refusedSources: Set<String> = []
        let operations = selection.flatMap { facts -> [CatalogueEditPlan.Intent] in
            let wanted = edits(facts)
            guard !wanted.isEmpty, wanted.allSatisfy({ $0.0.pair.occurrence.rootInstanceID == reader.rootInstanceID }),
                  let source = try? facts.file.get(), let refreshed = selected[key(facts, source)],
                  let refreshedFile = try? refreshed.file.get(), source.samePhysicalOccurrence(as: refreshedFile)
            else {
                refused += 1
                if let source = try? facts.file.get() { refusedSources.insert(source.pair.occurrence.relativePath) }
                return []
            }
            var intents: [CatalogueEditPlan.Intent] = []
            for (base, edit) in wanted {
                var member: CatalogueEditPlan.Member?
                switch edit.target {
                case .document(let id, _):
                    guard let resolved = try? refreshed.document.get(), id == resolved.document.id,
                          base.samePhysicalOccurrence(as: resolved.owner), facts.page?.id == refreshed.page?.id else {
                        refused += 1
                        refusedSources.insert(source.pair.occurrence.relativePath)
                        return []
                    }
                    if source.pair.occurrence != base.pair.occurrence {
                        member = .init(source: source, page: facts.page, document: id)
                    }
                case .pageViewRotation(let page):
                    guard refreshed.page?.id == page else {
                        refused += 1
                        return []
                    }
                case .file: break
                }
                intents.append(.init(base: base, edit: edit, member: member))
            }
            return intents
        }
        let plan = CatalogueEditPlan(operations)
        // `completed` hears of the PDFs asked for rather than the records written: with every document edited one PDF
        // may need several records (a split document's owner is another PDF's), and it is saved only when all are.
        var report = completed
        if documents != nil, let heard = completed {
            let needs = Dictionary(operations.map {
                (($0.member?.source ?? $0.base).pair.occurrence.relativePath, Set([$0.base.pair.occurrence.relativePath]))
            }, uniquingKeysWith: { $0.union($1) })
            report = { [refusedSources] written in
                heard(Set(needs.compactMap { source, records in
                    !refusedSources.contains(source) && records.isSubset(of: written) ? source : nil
                }))
            }
        }
        if plan.files.isEmpty, plan.refused + refused == 0 { return false }
        let preflightRefusals = plan.refused + refused
        let preflightFailures: [String]
        if preflightRefusals > 0, let rootPath = rootStore.discoveredPathPrefix {
            let accepted = Set(operations.map {
                UTF8Key(($0.member?.source ?? $0.base).pair.occurrence.relativePath)
            })
            preflightFailures = (paths ?? rows.map(\.path)).compactMap { path in
                let url = URL(fileURLWithPath: path)
                guard let relative = ReaderCatalogueScan.relativePath(of: url, under: rootPath),
                      !accepted.contains(UTF8Key(relative)) else { return nil }
                return "“\(relative)” has no verified catalogue field for this edit."
            } + plan.refusedPaths.map { "“\($0)” no longer has a consistent catalogue revision." }
        } else {
            preflightFailures = []
        }
        runCatalogueAction(reader: reader, verb: "Saved", completed: report) { journal in
            let writer = CatalogueWriter(reader: reader)
            let operation = CatalogueEditJournal.Operation(title: title, id: operationID ?? UUID())
            var result = CatalogueActionResult()
            result.unavailable = preflightRefusals
            result.failures = preflightFailures
            for file in plan.files {
                try result.attempt(operation, occurrence: file.base.pair.occurrence, journal: journal) {
                    try file.verifyMembership(in: reader)
                    return try writer.save(file.edits, basedOn: file.base)
                }
            }
            return result
        }
        return true
    }

    private func runCatalogueAction(reader: CatalogueReader, verb: String, completed: ((Set<String>) -> Void)? = nil,
                                    _ execute: @escaping @Sendable (CatalogueEditJournal.Session) throws -> CatalogueActionResult) {
        catalogueEditSaving = true
        catalogueEditFeedback = nil
        catalogueEditFailures = []
        Task { [weak self] in
            let journal = CatalogueEditJournal(rootID: reader.rootInstanceID)
            let output = await Task.detached(priority: .userInitiated) {
                Result { try journal.withSession { session in (try execute(session), session.history.heads) } }
            }.value
            // `completed` hears of every save that started, a refused one included, so a caller waiting on it
            // (the Tags window, W40.tag-window-reader) is never left waiting.
            guard let self else { completed?([]); return }
            self.catalogueEditSaving = false
            self.catalogueLastSaveChanged = 0
            guard self.catalogueReader?.rootInstanceID == reader.rootInstanceID, self.library.usesCatalogue else {
                self.catalogueHistoryRootID = nil
                self.refreshCatalogueEditHistory()
                completed?([])
                return
            }
            switch output {
            case .success(let (result, heads)):
                self.catalogueHistoryRootID = reader.rootInstanceID
                self.catalogueHistory = heads
                // FSEvents drops the Reader's own writes, so the list is revised for the companions written; a
                // write whose result is uncertain may have left either state, which only a full pass settles.
                if result.uncertain > 0 {
                    self.library.rescan()
                } else if !result.changedPaths.isEmpty {
                    self.library.reviseCatalogue(relativePaths: result.changedPaths.map {
                        CatalogueRecord.companionFilename(forPDFFilename: $0)
                    })
                }
                self.catalogueEditFailures = result.failures
                self.catalogueLastSaveChanged = result.changed
                self.reportCatalogue(result.message(verb: verb, pending: heads.uncertainCount))
                // The archive's Finder mirror follows each saved record (W49.storage-finder-reader-mirror).
                if self.finderMirrorOn, !result.changedPaths.isEmpty {
                    self.projectFinderMirror(changedRecords: result.changedPaths)
                }
                // A recorded tag change follows the Undo or Redo that changed something (W40.tag-window-reader).
                if let r = result.reversal, result.changed > 0 {
                    self.tagChangeReversed(group: r.group, by: r.by, redo: r.redo)
                }
                completed?(result.verifiedPaths)
            case .failure:
                self.catalogueHistoryRootID = nil
                self.refreshCatalogueEditHistory()
                self.library.rescan()
                self.reportCatalogue("Catalogue history could not be saved. Check the current values before trying again.")
                completed?([])
            }
        }
    }

    func reportCatalogue(_ message: String) {
        catalogueEditFeedback = message
        statusMessage = message
        announce(message)
    }

    private static func catalogueTagEdit(_ op: TagEditOp, id: UUID, fields: CatalogueRecord.DocumentFields) -> CatalogueEdit? {
        func edit(_ field: CatalogueEdit.DocumentField, _ change: CatalogueEdit.Change) -> CatalogueEdit {
            CatalogueEdit(.document(id, field), change)
        }
        func date(_ field: CatalogueEdit.DocumentField, _ value: ArchiveDate?, uncertain: Bool) -> CatalogueEdit {
            edit(field, value.map { .set(.date(.init(date: $0, uncertain: uncertain))) } ?? .clear)
        }
        let own = value(fields.documentDate)
        let sent = value(fields.sentWith)
        switch op {
        case .addSubject(let subject):
            let subjects = value(fields.subjects) ?? []
            let updated = subjects.contains(where: { isSameTag($0, subject) }) ? subjects : subjects + [subject]
            return edit(.subjects, .set(.names(updated)))
        case .removeSubject(let subject):
            return edit(.subjects, .set(.names((value(fields.subjects) ?? []).filter { !isSameTag($0, subject) })))
        case .setDate(let new): return date(.documentDate, new, uncertain: own?.uncertain ?? false)
        case .setDateUncertain(let uncertain):
            return own.map { date(.documentDate, $0.date, uncertain: uncertain) }
        case .setSentWith(let new): return date(.sentWith, new, uncertain: sent?.uncertain ?? false)
        case .setSentWithUncertain(let uncertain):
            return sent.map { date(.sentWith, $0.date, uncertain: uncertain) }
        case .setItemType(let type):
            return edit(.itemType, type.map { .set(.text($0.tokenName.lowercased())) } ?? .clear)
        case .setChecked(let field, let checked):
            return catalogueField(field).map { edit($0, .check(checked)) }
        case .setYear(let year):
            guard let year else { return date(.documentDate, nil, uncertain: false) }
            return ArchiveDate(year: year, month: own?.date.month, day: own?.date.day)
                .map { date(.documentDate, $0, uncertain: own?.uncertain ?? false) }
        case .setMonth(let month):
            return own.flatMap { prior in
                ArchiveDate(year: prior.date.year, month: month, day: month == nil ? nil : prior.date.day)
                    .map { date(.documentDate, $0, uncertain: prior.uncertain) }
            }
        case .setDay(let day):
            return own.flatMap { prior in
                ArchiveDate(year: prior.date.year, month: prior.date.month, day: day)
                    .map { date(.documentDate, $0, uncertain: prior.uncertain) }
            }
        case .setQuality: return nil
        }
    }

    nonisolated static func catalogueField(_ field: CheckableField) -> CatalogueEdit.DocumentField? {
        switch field {
        case .date: .documentDate
        case .sentWith: .sentWith
        case .documentKind: .documentKind
        case .title: .title
        case .byline: .byline
        case .publication: .publication
        case .publicationDate: .publicationDate
        case .recipientPlace: .recipientPlaces
        case .sender: .senders
        case .recipient: .recipients
        case .sendingPlace: .sendingPlaces
        }
    }

    nonisolated static func value<T>(_ field: CatalogueRecord.Field<T>?) -> T? where T: Decodable & Sendable {
        guard case .value(let current) = field?.current else { return nil }
        return current
    }
}

private extension ItemFacts {
    func catalogueDocumentEdit(_ make: (UUID, CatalogueRecord.DocumentFields) -> CatalogueEdit?)
        -> (ItemFacts.FileFacts, CatalogueEdit)? {
        guard let resolved = try? document.get(), let fields = resolved.document.fields,
              let edit = make(resolved.document.id, fields) else { return nil }
        return (resolved.owner, edit)
    }
}

private struct SelectionKey: Hashable {
    let occurrence: CatalogueAssociation.Occurrence
    let page: UUID?
}

private struct CatalogueEditPlan: Sendable {
    struct Intent: Sendable {
        let base: ItemFacts.FileFacts
        let edit: CatalogueEdit
        let member: Member?
    }

    struct Member: Sendable {
        let source: ItemFacts.FileFacts
        let page: CatalogueRecord.Page?
        let document: UUID

        /// The targeted read supplies file facts without resolving the entire archive again.
        /// Resolve the source membership here against the independently checked writer target.
        func stillRefers(to owner: UUID, in snapshot: CatalogueReader.Snapshot) -> Bool {
            let candidate = snapshot.facts(at: source.pair.occurrence.relativePath, physicalPageIndex: page?.physicalIndex)
            guard let live = try? candidate.file.get(), source.samePhysicalOccurrence(as: live) else { return false }
            let record = live.pair.record
            if let page {
                guard candidate.page?.id == page.id, candidate.page?.documentID == document else { return false }
            } else if record.documents.count != 1 || record.documents.first?.id != document {
                return false
            }
            return record.document(id: document)?.ownerFileID == owner
        }
    }

    struct ChangedMembership: Error {}

    struct File: Sendable {
        let base: ItemFacts.FileFacts
        let edits: [CatalogueEdit]
        let members: [Member]

        func verifyMembership(in reader: CatalogueReader) throws {
            guard !members.isEmpty else { return }
            let paths = members.map(\.source.pair.occurrence.relativePath)
            let selected = reader.snapshot(.init(relativePDFPaths: [], isComplete: false), including: paths)
            guard members.allSatisfy({ $0.stillRefers(to: base.revision.fileID, in: selected) }) else {
                throw ChangedMembership()
            }
        }
    }

    let files: [File]
    let refusedPaths: [String]
    var refused: Int { refusedPaths.count }

    init(_ operations: [Intent]) {
        let buckets = Dictionary(grouping: operations, by: { $0.base.pair.occurrence })
        var files: [File] = []
        var refusedPaths: [String] = []
        for (occurrence, group) in buckets {
            guard let base = group.first?.base, group.allSatisfy({ $0.base.revision == base.revision }) else {
                refusedPaths.append(occurrence.relativePath)
                continue
            }
            var seen: Set<CatalogueEdit.Target> = []
            let edits = group.map(\.edit).filter { seen.insert($0.target).inserted }
            files.append(File(base: base, edits: edits, members: group.compactMap(\.member)))
        }
        self.files = files.sorted { $0.base.pair.occurrence.relativePath.utf8.lexicographicallyPrecedes(
            $1.base.pair.occurrence.relativePath.utf8) }
        self.refusedPaths = refusedPaths.sorted()
    }
}

private struct CatalogueActionResult: Sendable {
    /// An Undo or Redo: the journal operation it reverses and its own.
    struct Reversal: Sendable { let group: UUID, by: UUID, redo: Bool }
    var reversal: Reversal?
    var changed = 0
    var unavailable = 0
    var uncertain = 0
    var verifiedPaths: Set<String> = []
    /// The PDFs whose companions this action rewrote.
    var changedPaths: [String] = []
    var failures: [String] = []

    mutating func attempt(_ operation: CatalogueEditJournal.Operation, occurrence: CatalogueAssociation.Occurrence,
                          journal: CatalogueEditJournal.Session, _ write: () throws -> CatalogueWriter.Receipt) throws {
        try journal.record(.intent(operation, occurrence))
        let outcome: CatalogueEditJournal.Outcome
        switch Result(catching: write) {
        case .success(let receipt):
            verifiedPaths.insert(occurrence.relativePath)
            if let inverse = receipt.inverse {
                changed += 1
                changedPaths.append(occurrence.relativePath)
                outcome = .changed(inverse)
            } else {
                outcome = .unchanged
            }
        case .failure(let error):
            if let failure = error as? CatalogueWriter.Failure, case .recoveryRequired(let artifact, _) = failure {
                uncertain += 1
                failures.append("“\(occurrence.relativePath)” needs recovery from “\(artifact)”.")
                outcome = .uncertain(artifact)
            } else {
                unavailable += 1
                let reason = Self.explain(error)
                failures.append("“\(occurrence.relativePath)”. " + reason)
                outcome = .refused(reason)
            }
        }
        try journal.record(.result(operation.id, occurrence, outcome))
    }

    private static func explain(_ error: Error) -> String {
        if error is CatalogueEditPlan.ChangedMembership {
            return "A selected PDF no longer refers to the same owning catalogue record."
        }
        if error is CatalogueWriter.Conflict || error is CatalogueWriter.UndoRefusal {
            return "The record or one of its fields changed since it was read."
        }
        if error as? CatalogueWriter.Failure == .unsupportedVolume {
            return "Catalogue changes require a local volume."
        }
        return "The PDF or its catalogue record could not be verified and saved."
    }

    func message(verb: String, pending: Int) -> String {
        let noun = changed == 1 ? "catalogue record" : "catalogue records"
        var result = changed > 0 ? "\(verb) \(changed) \(noun)." : "No catalogue records changed."
        if unavailable > 0 { result += " \(unavailable) could not be changed." }
        if let firstFailure = failures.first { result += " " + firstFailure }
        if pending > 0 { result += " Undo history is incomplete for \(pending) catalogue record(s)." }
        return result
    }
}
