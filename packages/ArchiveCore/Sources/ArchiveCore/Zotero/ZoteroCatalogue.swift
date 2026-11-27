import Foundation

// MARK: - Source facts from the catalogue record (W49.storage-notes-zotero; `SPEC/containers.md` §Zotero)
//
// Notes' source blocks, its year suggestion and the Reader's Zotero export read one PDF's facts through the same
// resolver: the exact occurrence a link or a selected row names, read only, under a grant the caller already holds.
// A PDF with a catalogue companion is described by that record alone. Its page-2 header, Finder tags, segment JSON
// sidecar and `.archivesuite/item-fields.json` are not consulted: a record that cannot be read never falls back to
// them, so a PDF separated from its companion cannot export an earlier correction as current. Only a PDF with no
// companion beside it, which opens and provably carries no catalogue identity, is a legacy file and is gathered as
// before, including one the catalogue's strict read refuses (a symbolic or hard link).

public enum CatalogueSourceFacts {
    /// One requested occurrence: a root-relative path and, for a page link, its 1-based page.
    public struct Selection: Hashable, Sendable {
        public let relativePath: String
        public let page: Int?

        public init(relativePath: String, page: Int? = nil) {
            self.relativePath = relativePath
            self.page = page
        }
    }

    public enum Resolution: Sendable {
        /// The record's facts: the linked page's document, or every document the file holds when no page is named.
        case catalogue([ItemFacts])
        /// No companion, and a PDF that provably carries no catalogue identity: a file that predates the catalogue.
        case unadopted
        /// The file's record cannot be used (missing beside an identified PDF, invalid, newer, offline, ambiguous).
        case unavailable(ItemFacts.Unavailable)
    }

    /// Resolves each selection under `grantedRoot`, whose security scope the caller holds. Exact paths only: a
    /// renamed or moved file is not searched for. A split document whose owner is another file needs the whole
    /// root's inventory; `inventoryForForeignOwners` allows one full walk for that, otherwise such a document
    /// reports `incompleteInventory`. A caller with its own pass of this root instance passes its `memory`, so that
    /// walk skips the parse of every unchanged file. Run off the main thread.
    public static func resolve(_ selections: [Selection], grantedRoot: URL, inventoryForForeignOwners: Bool,
                               memory: CatalogueReader.ReadMemory? = nil,
                               identifyPDF: @escaping CatalogueReader.IdentifyPDF = CataloguePDFIdentity.identify)
        -> [Resolution] {
        guard !selections.isEmpty else { return [] }
        guard let reader = try? CatalogueReader(grantedRoot: grantedRoot, rootInstanceID: memory?.rootInstanceID ?? UUID(),
                                                mode: .adopted, identifyPDF: identifyPDF) else {
            return selections.map { _ in .unavailable(.invalid(.root)) }
        }
        let paths = selections.map(\.relativePath)
        let resolve = { (snapshot: CatalogueReader.Snapshot) in
            selections.map { Self.resolve($0, in: snapshot, grantedRoot: grantedRoot) }
        }
        var snapshot = reader.snapshot(.init(relativePDFPaths: [], isComplete: false), including: paths, remembering: memory)
        var resolved = resolve(snapshot)
        let needsOwners = resolved.contains { resolution in
            guard case .catalogue(let facts) = resolution else { return false }
            return facts.contains { if case .failure(.incompleteInventory) = $0.document { true } else { false } }
        }
        if needsOwners, inventoryForForeignOwners {
            snapshot = reader.discover(including: paths, remembering: memory)
            resolved = resolve(snapshot)
        }
        return resolved
    }

    static func resolve(_ selection: Selection, in snapshot: CatalogueReader.Snapshot, grantedRoot: URL) -> Resolution {
        let facts = snapshot.facts(at: selection.relativePath)
        let file: ItemFacts.FileFacts
        switch facts.file {
        case .success(let read):
            file = read
        case .failure(let failure):
            return unadopted(selection.relativePath, failure: failure, in: snapshot, grantedRoot: grantedRoot)
        }
        if let page = selection.page {
            // A page outside the record reports the missing document rather than another page's facts.
            return .catalogue([snapshot.facts(at: selection.relativePath, physicalPageIndex: page - 1)])
        }
        // A file-level selection describes each document, in page order, from its first page.
        var firstPage: [UUID: Int] = [:]
        for page in file.pair.record.pages {
            firstPage[page.documentID] = min(firstPage[page.documentID] ?? page.physicalIndex, page.physicalIndex)
        }
        let documents = file.pair.record.documents.compactMap { document in firstPage[document.id].map { (document, $0) } }
            .sorted { $0.1 < $1.1 }
        return .catalogue(documents.map { snapshot.facts(at: selection.relativePath, physicalPageIndex: $0.1) })
    }

    /// Whether a file whose catalogue read failed is a legacy file. Only a failure about the PDF itself qualifies (no
    /// companion, a link the strict read refuses, an unreadable identity), and only with no companion beside it and
    /// a PDF that provably carries no identity. Anything else is reported, never replaced by earlier facts.
    static func unadopted(_ relativePath: String, failure: ItemFacts.Unavailable, in snapshot: CatalogueReader.Snapshot,
                          grantedRoot: URL) -> Resolution {
        switch failure {
        case .missing(.companion), .invalid(.pdf): break
        default: return .unavailable(failure)
        }
        // Only a path the catalogue's own read accepts (no `..`, no empty component) is opened here.
        guard CatalogueReader.pathComponents(relativePath) != nil else { return .unavailable(failure) }
        // An identified PDF without its companion is a separated catalogue file, not a legacy one.
        if snapshot.reads[Data(relativePath.utf8)]?.identity != nil { return .unavailable(failure) }
        let pdf = grantedRoot.appendingPathComponent(relativePath)
        let companion = pdf.deletingLastPathComponent()
            .appendingPathComponent(CatalogueRecord.companionFilename(forPDFFilename: pdf.lastPathComponent))
        var info = stat()
        let companionBeside = companion.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &info) == 0 } ?? true }
        if companionBeside, failure != .missing(.companion) { return .unavailable(failure) }
        guard !companionBeside, CataloguePDFIdentity.provablyAbsent(at: pdf) else {
            return .unavailable(failure == .missing(.companion) ? .invalid(.pdf) : failure)
        }
        return .unadopted
    }

    /// The year a selection's own date names, when every document it describes agrees on one. Nil for a decade,
    /// an undated or unavailable record, and a legacy file (whose caller reads its tags).
    public static func year(_ resolution: Resolution) -> Int? {
        guard case .catalogue(let selections) = resolution, !selections.isEmpty else { return nil }
        let years = selections.map { facts -> Int? in
            guard let fields = (try? facts.document.get())?.document.fields,
                  case .value(let value)? = fields.documentDate?.current, value.date.precision != .decade else { return nil }
            return value.date.year
        }
        guard let first = years.first ?? nil, years.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

extension ZoteroSource {
    /// The source for one resolved selection, from its catalogue record alone. A document that cannot be resolved
    /// keeps the file name, container and link, and says why in `catalogueUnavailable`.
    public init(fileName: String, facts: ItemFacts, container: [ContainerField: String] = [:], link: String? = nil) {
        self.init(fileName: fileName, container: container, link: link)
        switch facts.document {
        case .failure(let failure):
            catalogueUnavailable = failure.zoteroReason
        case .success(let resolved):
            guard let fields = resolved.document.fields else {
                catalogueUnavailable = ItemFacts.Unavailable.invalid(.owner).zoteroReason
                return
            }
            tags = Self.tags(fields)
            func value<V>(_ field: CatalogueRecord.Field<V>?) -> V? {
                if case .value(let value)? = field?.current { return value }
                return nil
            }
            func list(_ field: CatalogueRecord.Field<[String]>?) -> [String] {
                (value(field) ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            func joined(_ field: CatalogueRecord.Field<[String]>?) -> String? {
                let all = list(field)
                return all.isEmpty ? nil : all.joined(separator: "; ")
            }
            func text(_ field: CatalogueRecord.Field<String>?) -> String? {
                value(field).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
            }
            itemFields = PDFItemFields(documentKind: text(fields.documentKind)?.lowercased(), title: text(fields.title),
                                       byline: joined(fields.byline), publication: text(fields.publication),
                                       publicationDate: value(fields.publicationDate)?.date.wireValue,
                                       recipientPlace: joined(fields.recipientPlaces))
            var people = ZoteroSidecar()
            people.authors = list(fields.senders)
            people.recipients = list(fields.recipients)
            people.authorPlaces = list(fields.sendingPlaces)
            people.recipientPlaces = list(fields.recipientPlaces)
            sidecar = people
        }
    }

    /// Everything for one Notes source or Reader row under `grantedRoot`: the catalogue record's documents, the
    /// legacy gathering for a file with no catalogue identity, or one item saying why the record is unavailable.
    public static func gather(_ resolution: CatalogueSourceFacts.Resolution, pdf: URL,
                              container: @autoclosure () -> [ContainerField: String], link: String? = nil) -> [ZoteroSource] {
        switch resolution {
        case .unadopted:
            var source = gather(pdf: pdf, lookup: nil, link: link)
            source.container = container()
            return [source]
        case .catalogue(let selections):
            let shown = container()
            return selections.map { ZoteroSource(fileName: pdf.lastPathComponent, facts: $0, container: shown, link: link) }
        case .unavailable(let failure):
            var source = ZoteroSource(fileName: pdf.lastPathComponent, container: container(), link: link)
            source.catalogueUnavailable = failure.zoteroReason
            return [source]
        }
    }

    /// The date and subjects as the export maps them, from the record's typed values.
    static func tags(_ fields: CatalogueRecord.DocumentFields) -> DocumentTags {
        func value<V>(_ field: CatalogueRecord.Field<V>?) -> V? {
            if case .value(let value)? = field?.current { return value }
            return nil
        }
        let own = value(fields.documentDate)
        let sentWith = value(fields.sentWith)
        let decade = own?.date.precision == .decade ? own?.date.year : nil
        let year = decade == nil ? own?.date.year : nil
        let month = own?.date.month.map { DocumentTags.Month(number: $0, name: DocumentTags.monthNames[$0 - 1]) }
        return DocumentTags(raw: [], labelNumber: nil, year: year, month: month, day: own?.date.day,
                            dateUncertain: own?.uncertain ?? false, decade: decade, quality: nil, readState: nil,
                            itemType: nil, subjects: value(fields.subjects) ?? [], yearToken: nil, monthToken: nil,
                            dayToken: nil, decadeToken: own.flatMap { $0.date.precision == .decade ? $0.date.wireValue : nil },
                            qualityToken: nil, sentWith: sentWith?.date, sentWithUncertain: sentWith?.uncertain ?? false)
    }
}

extension ItemFacts.Unavailable {
    /// Why the record gave nothing, as the export's `note` line says it.
    var zoteroReason: String {
        func name(_ artifact: ItemFacts.Artifact) -> String {
            switch artifact {
            case .root: "the archive folder"
            case .pdf: "the PDF"
            case .companion: "the catalogue companion"
            case .document: "the document"
            case .owner: "the file that holds the document's facts"
            }
        }
        switch self {
        case .legacy: return "the folder does not use catalogue companions"
        case .offline(let artifact): return "\(name(artifact)) is not downloaded"
        case .missing(.document): return "the linked page is not in the catalogue record"
        case .missing(let artifact): return "\(name(artifact)) is missing"
        case .invalid(let artifact): return "\(name(artifact)) could not be verified"
        case .ambiguous(.document): return "the file holds several documents and the link names no page"
        case .ambiguous(let artifact): return "more than one copy of \(name(artifact)) was found"
        case .newer(let schema): return "the catalogue companion is a newer format (schema \(schema))"
        case .incompleteInventory: return "the file that holds the document's facts was not looked for"
        }
    }
}
