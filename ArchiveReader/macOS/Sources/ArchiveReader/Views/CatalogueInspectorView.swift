import ArchiveCore
import ArchiveCoreUI
import SwiftUI

struct CatalogueInspectorView: View {
    let model: NavigationModel
    let paths: [String]
    let physicalPageIndex: Int?
    let isVisible: Bool
    let onClose: () -> Void
    @StateObject private var feed = InspectorFeed()
    @Environment(\.undoManager) private var undoManager
    @State private var chosenPage: Int?

    var body: some View {
        let rows = model.library.files(atPaths: paths)
        let page = physicalPageIndex ?? chosenPage
        let facts = rows.compactMap { model.catalogueFacts(for: $0, physicalPageIndex: page) }
        VStack(spacing: 0) {
            HStack {
                Text(rows.count <= 1 ? "Inspector" : "Inspector — \(rows.count) files").font(.headline)
                Spacer()
                Button("Close", action: onClose).accessibilityIdentifier("ar.tagEditor.done")
            }
            .padding()
            if let row = rows.first, rows.count == 1 {
                Text(row.name).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).padding(.horizontal).padding(.bottom, 8)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let feedback = model.catalogueEditFeedback {
                        Text(feedback).font(.callout).foregroundStyle(.secondary)
                    }
                    if model.catalogueEditFailures.count > 1 {
                        DisclosureGroup("Files that need attention") {
                            ForEach(Array(model.catalogueEditFailures.enumerated()), id: \.offset) { _, failure in
                                Text(failure).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.catalogueEditSaving { ProgressView().controlSize(.small) }
                    if let unavailable = facts.compactMap({ failure($0.file) }).first {
                        Label(message(unavailable), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                    } else if rows.isEmpty || facts.isEmpty {
                        Text("Catalogue information is unavailable.").foregroundStyle(.secondary)
                    }
                    if rows.count == 1, let row = rows.first, let fact = facts.first,
                       case .failure(.missing(.companion)) = fact.file,
                       let reader = model.catalogueReader, let root = model.rootStore.root,
                       let rootPath = model.rootStore.discoveredPathPrefix,
                       let relative = ReaderCatalogueScan.relativePath(of: row.url, under: rootPath) {
                        CatalogueRepairSection(navigation: model, reader: reader, root: root,
                                               relativePath: relative, revision: fact.revision)
                    }
                    if physicalPageIndex == nil, rows.count == 1,
                       let row = rows.first, row.catalogueDocuments.count > 1 {
                        Picker("Document", selection: $chosenPage) {
                            Text("Choose a document").tag(nil as Int?)
                            ForEach(row.catalogueDocuments.compactMap(\.page).sorted { $0.physicalIndex < $1.physicalIndex },
                                    id: \.id) { page in
                                Text("From page \(page.physicalIndex + 1)").tag(page.physicalIndex as Int?)
                            }
                        }
                        .accessibilityIdentifier("ar.catalogue.document")
                    }
                    if facts.contains(where: { (try? $0.document.get()) != nil }) {
                        documentSection(facts, page: page).id(page)
                        Divider()
                    } else if let unavailable = facts.compactMap({ failure($0.document) }).first,
                              facts.contains(where: { (try? $0.file.get()) != nil }) {
                        Text(message(unavailable)).foregroundStyle(.secondary)
                    }
                    if facts.contains(where: { (try? $0.file.get()) != nil }) {
                        fileSection(facts)
                        Divider()
                    }
                    containers(for: rows)
                    if rows.count == 1, let row = rows.first {
                        CollectionRecordView(fileURL: row.url, root: model.rootStore.root, identifierPrefix: "ar")
                    }
                }
                .padding()
            }
            .disabled(model.catalogueEditSaving)
        }
        .onAppear { feed.follow(model, visible: isVisible) }
        .onChange(of: isVisible) { _, visible in feed.follow(model, visible: visible) }
        .modifier(ContainerSetAsideAlert(model: model, window: undoManager.map(ObjectIdentifier.init)))
    }

    private func failure<T>(_ result: Result<T, ItemFacts.Unavailable>) -> ItemFacts.Unavailable? {
        if case .failure(let error) = result { return error }
        return nil
    }

    private func message(_ failure: ItemFacts.Unavailable) -> String {
        switch failure {
        case .legacy: "This folder uses Finder tags."
        case .offline(.pdf): "The PDF is offline."
        case .offline: "Catalogue information is offline."
        case .missing(.companion): "The catalogue companion is missing."
        case .missing(.owner): "The PDF that holds this document’s catalogue fields is missing."
        case .missing: "Catalogue information is missing."
        case .invalid: "Reader couldn’t verify the catalogue information."
        case .ambiguous(.document): "Choose a document in this PDF to see its catalogue fields."
        case .ambiguous: "Reader found more than one possible catalogue match."
        case .newer: "The catalogue companion uses a newer format."
        case .incompleteInventory: "Reader couldn’t check every file in this folder."
        }
    }

    private typealias Document = CatalogueRecord.DocumentFields
    private typealias File = CatalogueRecord.FileFields

    private func documentSection(_ facts: [ItemFacts], page: Int?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Document").font(.headline)
            date("Date", .documentDate, \.documentDate, facts, page)
            date("Sent with", .sentWith, \.sentWith, facts, page)
            if facts.count == 1, let enclosure = facts.first?.enclosure {
                switch enclosure {
                case .success(let linked):
                    let name = (linked.owner.pair.occurrence.relativePath as NSString).lastPathComponent
                    let title = linked.document.fields?.title?.readerValue ?? name
                    LabeledContent("Enclosed with", value: title)
                        .help(name)
                case .failure(let error):
                    LabeledContent("Enclosed with", value: message(error))
                }
            }
            date("Publication date", .publicationDate, \.publicationDate, facts, page)
            text("Kind", .documentKind, \.documentKind, facts, page)
            text("Title", .title, \.title, facts, page)
            entries("Byline", .byline, \.byline, facts, page)
            text("Publication", .publication, \.publication, facts, page)
            entries("Sender", .senders, \.senders, facts, page)
            entries("Recipient", .recipients, \.recipients, facts, page)
            entries("Sending place", .sendingPlaces, \.sendingPlaces, facts, page)
            entries("Recipient place", .recipientPlaces, \.recipientPlaces, facts, page)
            entries("Subjects", .subjects, \.subjects, facts, page)
            let type = documentValue(\.itemType, facts)
            Menu("Item type — \(type.text { $0.capitalized })") {
                Button("Box") { edit(.itemType, .set(.text("box")), page, facts) }
                Button("Folder") { edit(.itemType, .set(.text("folder")), page, facts) }
                Button("None") { edit(.itemType, .clear, page, facts) }
            }
            if facts.count == 1, let fields = ReaderCatalogueFacets.document(facts.first) {
                evidence(for: fields)
            }
        }
    }

    @ViewBuilder private func evidence(for fields: Document) -> some View {
        let groups = [
            evidenceLines("Date", fields.documentDate), evidenceLines("Sent with", fields.sentWith),
            evidenceLines("Publication date", fields.publicationDate), evidenceLines("Kind", fields.documentKind),
            evidenceLines("Title", fields.title), evidenceLines("Publication", fields.publication),
            evidenceLines("Byline", fields.byline), evidenceLines("Sender", fields.senders),
            evidenceLines("Recipient", fields.recipients), evidenceLines("Sending place", fields.sendingPlaces),
            evidenceLines("Recipient place", fields.recipientPlaces)
        ]
        let lines = groups.flatMap { $0 }
        if !lines.isEmpty {
            DisclosureGroup("Catalogue evidence") {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private func evidenceLines<Value: Decodable & Sendable>(_ label: String, _ field: CatalogueRecord.Field<Value>?) -> [String] {
        (field?.evidence ?? []).map { evidence in
            var text = "\(label) · \(evidence.source)"
            if let route = evidence.route, route != evidence.source { text += " · " + route }
            if let quote = evidence.quote, !quote.isEmpty { text += "\n" + quote }
            return text
        }
    }

    private func fileSection(_ facts: [ItemFacts]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PDF").font(.headline)
            let read = fileValue(\.readState, facts)
            Menu("Read state — \(read.text { $0.capitalized })") {
                Button("Read") { fileEdit(.readState, .set(.text("read")), facts) }
                Button("Unread") { fileEdit(.readState, .set(.text("unread")), facts) }
                Button("Neither") { fileEdit(.readState, .clear, facts) }
            }
            let colour = fileValue(\.colour, facts)
            Menu("Colour — \(colour.text { $0.capitalized })") {
                Button("None") { fileEdit(.colour, .clear, facts) }
                ForEach(FinderLabel.allCases, id: \.rawValue) { colour in
                    Button(colour.tokenName) { fileEdit(.colour, .set(.text(colour.tokenName.lowercased())), facts) }
                }
            }
            let quality = fileValue(\.quality, facts)
            Menu("Quality — \(quality.text { String($0) })") {
                Button("Unrated") { fileEdit(.quality, .clear, facts) }
                ForEach(QualityLevels.all, id: \.self) { quality in
                    Button(String(quality)) { fileEdit(.quality, .set(.rating(quality)), facts) }
                }
            }
            flag("Flagged", .flagged, \.flagged, facts)
            flag("OCR Poor", .ocrPoor, \.ocrPoor, facts)
            if fileValue(\.ocrFailed, facts).value == true {
                Label("OCR Failed", systemImage: "exclamationmark.triangle")
            }
        }
    }

    @ViewBuilder private func containers(for rows: [ArchiveFile]) -> some View {
        if rows.count == 1, let row = rows.first, model.containerCatalog.rootPath == model.containerTree?.path,
           let editor = model.containerCatalog.editor(forPath: row.path) {
            ContainerSection(detail: model.containerCatalog.detail(forPath: row.path), editor: editor,
                             error: model.containerEditError, saving: model.containerEditSaving,
                             onEdit: { model.editContainerField($0, $1, forPath: row.path, undo: undoManager) },
                             onName: { model.setContainerStandardName($2, for: $1, field: $0,
                                                                      forPath: row.path, undo: undoManager) },
                             onShowWarning: { model.selectContainerWarning($0) })
        } else if rows.count > 1, model.containerCatalog.rootPath == model.containerTree?.path {
            ContainerSelectionSection(count: rows.count, error: model.containerEditError,
                                      saving: model.containerEditSaving,
                                      onSet: { model.setContainerFieldForSelection($0, $1, paths: paths, undo: undoManager) })
        }
    }

    private func text(_ label: String, _ field: CatalogueEdit.DocumentField,
                      _ key: KeyPath<Document, CatalogueRecord.Field<String>?>, _ facts: [ItemFacts], _ page: Int?) -> some View {
        let value = documentValue(key, facts)
        return VStack(alignment: .leading, spacing: 4) {
            CatalogueDraft(label: label, identifier: field.rawValue, initial: value.value ?? "",
                           placeholder: value.placeholder, facts: facts) { value, observed in
                edit(field, value.isEmpty ? .clear : .set(.text(value)), page, observed)
                return nil
            }
            check(field, key, facts, page)
        }
    }

    private func date(_ label: String, _ field: CatalogueEdit.DocumentField,
                      _ key: KeyPath<Document, CatalogueRecord.Field<CatalogueRecord.DateValue>?>,
                      _ facts: [ItemFacts], _ page: Int?) -> some View {
        let value = documentValue(key, facts)
        return VStack(alignment: .leading, spacing: 4) {
            CatalogueDraft(label: label, identifier: field.rawValue, initial: value.value?.date.wireValue ?? "",
                           placeholder: value.placeholder, facts: facts) { string, observed in
                let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { edit(field, .clear, page, observed); return nil }
                guard let date = ArchiveDate.parse(wireValue: text) else { return "Enter a year, YYYY-MM, YYYY-MM-DD or a decade such as 1950s." }
                let original = documentValue(key, observed).value
                edit(field, .set(.date(.init(date: date, uncertain: original?.uncertain ?? false))), page, observed)
                return nil
            }
            if let current = value.value {
                Toggle("Uncertain", isOn: Binding(get: { current.uncertain }, set: {
                    edit(field, .set(.date(.init(date: current.date, uncertain: $0))), page, facts)
                }))
                .toggleStyle(.checkbox)
            }
            check(field, key, facts, page)
        }
    }

    private func entries(_ label: String, _ field: CatalogueEdit.DocumentField,
                         _ key: KeyPath<Document, CatalogueRecord.Field<[String]>?>,
                         _ facts: [ItemFacts], _ page: Int?) -> some View {
        let value = documentValue(key, facts)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline)
            let names = value.value ?? []
            ForEach(names.indices, id: \.self) { index in
                CatalogueDraft(label: "\(label) \(index + 1)", identifier: "\(field.rawValue).\(index)",
                               initial: names[index], placeholder: "", facts: facts, showsLabel: false) { string, observed in
                    guard var original = documentValue(key, observed).value, original.indices.contains(index) else {
                        return "This list changed. Review its current values before editing."
                    }
                    if string.isEmpty { original.remove(at: index) }
                    else { original[index] = string }
                    edit(field, original.isEmpty ? .clear : .set(.names(original)), page, observed)
                    return nil
                }
            }
            CatalogueDraft(label: label, identifier: field.rawValue, initial: "",
                           placeholder: value.placeholder.isEmpty ? "Add a value" : value.placeholder,
                           facts: facts, showsLabel: false, clearOnCommit: true, submitOnly: field == .subjects) { string, observed in
                guard !string.isEmpty else { return nil }
                model.updateCatalogueNames(field, paths: paths, physicalPageIndex: page, observed: observed) { names in
                    if field == .subjects, names.contains(where: { isSameTag($0, string) }) { return names }
                    return names + [string]
                }
                return nil
            }
            if field != .subjects { check(field, key, facts, page) }
        }
    }

    private func check<V: Decodable & Sendable>(_ field: CatalogueEdit.DocumentField,
                          _ key: KeyPath<Document, CatalogueRecord.Field<V>?>, _ facts: [ItemFacts], _ page: Int?) -> some View {
        let values = facts.compactMap { (try? $0.document.get())?.document.fields?[keyPath: key] }
        let checked = !values.isEmpty && values.allSatisfy(\.isChecked)
        return Toggle("Checked", isOn: Binding(get: { checked }, set: { edit(field, .check($0), page, facts) }))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("ar.catalogue.check.\(field.rawValue)")
            .disabled(values.isEmpty)
    }

    private func flag(_ label: String, _ field: CatalogueEdit.FileField,
                      _ key: KeyPath<File, CatalogueRecord.Field<Bool>?>, _ facts: [ItemFacts]) -> some View {
        let value = fileValue(key, facts)
        return Toggle(value.value == nil ? "\(label) — \(value.placeholder)" : label,
                      isOn: Binding(get: { value.value == true },
                                    set: { fileEdit(field, .set(.flag($0)), facts) }))
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("ar.catalogue.\(field.rawValue)")
    }

    private func edit(_ field: CatalogueEdit.DocumentField, _ change: CatalogueEdit.Change,
                      _ page: Int?, _ observed: [ItemFacts]) {
        model.applyCatalogueDocumentField(field, change, paths: paths, physicalPageIndex: page, observed: observed)
    }

    private func fileEdit(_ field: CatalogueEdit.FileField, _ change: CatalogueEdit.Change, _ observed: [ItemFacts]) {
        model.applyCatalogueFileField(field, change, paths: paths, observed: observed)
    }

    private func documentValue<V: Equatable & Decodable & Sendable>(_ key: KeyPath<Document, CatalogueRecord.Field<V>?>,
                                  _ facts: [ItemFacts]) -> SharedCatalogueValue<V> {
        SharedCatalogueValue(facts.map { fact in
            guard let fields = (try? fact.document.get())?.document.fields else { return .unavailable }
            return .init(fields[keyPath: key])
        })
    }

    private func fileValue<V: Equatable & Decodable & Sendable>(_ key: KeyPath<File, CatalogueRecord.Field<V>?>,
                              _ facts: [ItemFacts]) -> SharedCatalogueValue<V> {
        SharedCatalogueValue(facts.map { fact in
            guard let fields = (try? fact.file.get())?.pair.record.fileFields else { return .unavailable }
            return .init(fields[keyPath: key])
        })
    }
}

private enum SharedCatalogueValue<V: Equatable & Decodable & Sendable>: Equatable {
    case value(V), cleared, unassessed, unavailable, mixed

    init(_ field: CatalogueRecord.Field<V>?) {
        guard let field else { self = .unassessed; return }
        switch field.current {
        case .value(let value): self = .value(value)
        case .cleared: self = .cleared
        }
    }

    init(_ values: [Self]) {
        guard let first = values.first else { self = .unavailable; return }
        self = values.allSatisfy { $0 == first } ? first : .mixed
    }

    var value: V? {
        if case .value(let value) = self { return value }
        return nil
    }

    var placeholder: String {
        switch self {
        case .value: ""
        case .cleared: "Cleared"
        case .unassessed: "Unassessed"
        case .unavailable: "Unavailable"
        case .mixed: "Mixed"
        }
    }

    func text(_ format: (V) -> String) -> String { value.map(format) ?? placeholder }
}

private struct CatalogueDraft: View {
    let label: String
    let identifier: String
    let initial: String
    let placeholder: String
    let facts: [ItemFacts]
    var showsLabel = true
    var clearOnCommit = false
    var submitOnly = false
    let apply: (String, [ItemFacts]) -> String?

    @State private var draft = ""
    @State private var observed: [ItemFacts]?
    @State private var edited = false
    @State private var hint: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsLabel { Text(label).font(.subheadline) }
            TextField(label, text: Binding(get: { draft }, set: { draft = $0; edited = true }),
                      prompt: Text(placeholder))
                .accessibilityIdentifier("ar.catalogue.\(identifier)")
                .focused($focused)
                .onSubmit(commit)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { draft = initial }
        .onChange(of: initial) { _, value in
            if !focused, !edited { draft = value }
        }
        .onChange(of: focused) { _, focused in
            if focused {
                if !edited { observed = facts }
            } else if !submitOnly {
                commit()
            }
        }
    }

    private func commit() {
        guard edited else { return }
        hint = apply(draft, observed ?? facts)
        if hint == nil {
            edited = false
            observed = nil
            if clearOnCommit { draft = "" }
        }
    }
}
