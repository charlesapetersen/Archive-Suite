import SwiftUI
import ArchiveCore

/// W47.ct-processor-capture — the marker card: a box or folder label photo's read fields, shown through
/// `ContainerDisplay.values` with the output folder's standard names (W47.ct-normalise), for the operator to correct in
/// the reading room. Save makes every value the operator's (source `user`); Skip leaves the read's proposals as they
/// are (source `label`), for the Reader's editor. Either way they are written beside the collection's files at Finish.
struct ContainerLabelCard: View {
    let group: CaptureGroup
    let type: ItemType
    @ObservedObject var session: CaptureSession

    /// The text in each field, and what it started as (the shown value), so an untouched field keeps its value as
    /// written rather than the title-cased or standard name it was shown as.
    @State private var texts: [ContainerField: String] = [:]
    @State private var shown: [ContainerField: String] = [:]
    @State private var persistFailure: String? = nil

    static func fields(for type: ItemType) -> [ContainerField] {
        switch type {
        case .box: return [.repository, .collectionTitle, .collectionSubtitle, .collectionNumber, .accession, .series,
                           .seriesTitle, .container, .boxTitle, .date, .other]
        case .folder: return [.folder, .folderTitle, .date, .other]
        }
    }

    private var read: ContainerFieldSet { session.containerFields[group.id] ?? ContainerFieldSet() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(type == .box ? "Box label" : "Folder label").font(.title2).fontWeight(.semibold)
            Text("Read from the photo. Correct anything wrong and fill in what is missing; leave a field empty if the label does not say it. Saved beside the collection's files when you finish.")
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let fallback = session.containerFallbacks[group.id] {
                Label(fallback.cardNote, systemImage: "info.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ap.container.fallback")
            }

            HStack(alignment: .top, spacing: 14) {
                if let photo = group.photos.first {
                    ArchiveThumbnail(url: photo.url, maxSize: 480)
                        .frame(width: 180, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(Self.fields(for: type), id: \.self) { field in
                        GridRow {
                            Text(field == .container ? "Box" : field.label).font(.callout)
                                .gridColumnAlignment(.trailing)
                            TextField(placeholder(field), text: binding(field))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 260)
                                .accessibilityIdentifier("ap.container.\(field.rawValue)")
                        }
                    }
                }
            }

            if type == .box, read[.container] == nil {
                Label("No box number was read. Type it if the label has one.", systemImage: "questionmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let persistFailure {
                Label(persistFailure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Skip") { skip() }
                    .help("Keep what was read as proposals, to confirm later in Archive Reader.")
                Spacer()
                Button("Save ▸") { save() }
                    .keyboardShortcut(.defaultAction)
                    .prominentButtonStyle()
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func placeholder(_ field: ContainerField) -> String {
        guard let reader = read[field]?.reader, read[field]?.source == .label else { return "" }
        return "read by \(reader)"
    }

    private func binding(_ field: ContainerField) -> Binding<String> {
        Binding(get: { texts[field] ?? "" }, set: { texts[field] = $0 })
    }

    private func load() {
        persistFailure = nil
        let record = ResolvedContainer(values: read.values)
        let display = ContainerDisplay.values(record, names: session.liveProcessor.containerNames)
        var t: [ContainerField: String] = [:]
        for field in Self.fields(for: type) { if let s = display[field]?.text { t[field] = s } }
        texts = t
        shown = t
    }

    /// What Save stores, as the operator's (source `user`):
    /// - a field left as shown keeps the read's value as written, and the reader that proposed it, even where the
    ///   display was a standard name or showed nothing; a field the read did not give (a standard name's fill from
    ///   another field) stores nothing, since the display is not a value;
    /// - an edited field stores the text typed, trimmed; an emptied one stores nothing.
    static func confirmed(texts: [ContainerField: String], shown: [ContainerField: String], read: ContainerFieldSet,
                          fields: [ContainerField], at date: Date) -> ContainerFieldSet {
        var out = ContainerFieldSet()
        for field in fields {
            let typed = texts[field] ?? ""
            if typed == (shown[field] ?? "") {
                if let original = read[field] { out[field] = original.confirmed(at: date) }
                continue
            }
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out[field] = ContainerValue(text, source: .user, at: date) }
        }
        return out
    }

    private func save() {
        let fields = Self.confirmed(texts: texts, shown: shown, read: read, fields: Self.fields(for: type), at: Date())
        persistFailure = session.applyContainerFields(groupId: group.id, fields: fields)
            ? nil : CaptureSession.tagDecisionNotDurableMessage
    }

    private func skip() {
        persistFailure = session.skipMacTags(groupId: group.id) ? nil : CaptureSession.tagDecisionNotDurableMessage
    }
}
