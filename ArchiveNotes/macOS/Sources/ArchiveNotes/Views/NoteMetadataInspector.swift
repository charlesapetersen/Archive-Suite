import SwiftUI

/// The detail-pane **metadata strip** for the selected note/extract (W6-S7, 06-viewers §7/§8): edit the
/// document DATE (precision + precision-appropriate fields + a "date uncertain" toggle) and the QUALITY
/// rating. Both write **front-matter only** through `NotesNavigationModel` → `NotesModel`
/// (00-overview D2/D9) — this view NEVER touches a Finder tag / `NotesTagProjector`.
///
/// Adapted from Reader's `InlineEditCells.DateCell` + `TagEditorView.dateSection`/`prioritySection`,
/// retargeted from tag writes to the Notes front-matter store. Local field state is seeded from the
/// selected `ItemSummary` on selection change and committed on explicit user action (segmented-control
/// / month-menu bindings + "Set" buttons) — never on the programmatic seed, so selecting an item never
/// rewrites its date. Each edit composes a canonical string for the chosen precision and calls the
/// async setter, which normalizes (`Item.normalizedDate`: decade floors the year; month/day downgrade
/// when a lower field is missing), persists atomically, and re-indexes.
///
/// The field rules — what a commit composes, whether the day row's "Set" is live, and the note shown
/// for a day the chosen month cannot have (`Feb 31`, W23.l4) — live in `DateFieldEntry` so they are
/// unit-testable without a window; this view is the `@State` + bindings layer over them.
struct NoteMetadataInspector: View {
    @ObservedObject var nav: NotesNavigationModel
    let item: ItemSummary

    @State private var precision: Item.DatePrecision = .year
    @State private var yearText = ""
    @State private var month = 0          // 0 = none
    @State private var dayText = ""

    private static let monthNames = DateFieldEntry.monthNames

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            dateSection
            Divider()
            qualitySection
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { seed(from: item) }
        .onChange(of: item.id) { seed(from: item) }   // re-seed only on selection change (WYSIWYG typing)
        .accessibilityIdentifier("an.detail.metadata")
    }

    // MARK: Date

    @ViewBuilder private var dateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date").font(.subheadline.bold())
            Picker("Precision", selection: precisionBinding) {
                Text("Decade").tag(Item.DatePrecision.decade)
                Text("Year").tag(Item.DatePrecision.year)
                Text("Month").tag(Item.DatePrecision.month)
                Text("Day").tag(Item.DatePrecision.day)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("an.detail.date.precision")

            HStack {
                Text(precision == .decade ? "Decade" : "Year").frame(width: 54, alignment: .leading)
                TextField(precision == .decade ? "e.g. 1970" : "e.g. 1968", text: $yearText)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { commit() }
                    .accessibilityIdentifier("an.detail.date.year")
                Button("Set") { commit() }
                    .disabled((Int(yearText.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
                Button("Clear") { yearText = ""; month = 0; dayText = ""; commit() }
            }

            if precision == .month || precision == .day {
                HStack {
                    Text("Month").frame(width: 54, alignment: .leading)
                    Picker("", selection: monthBinding) {
                        Text("—").tag(0)
                        ForEach(1...12, id: \.self) { m in Text(Self.monthNames[m - 1]).tag(m) }
                    }
                    .labelsHidden().frame(width: 150)
                    .accessibilityIdentifier("an.detail.date.month")
                }
            }

            if precision == .day {
                HStack {
                    Text("Day").frame(width: 54, alignment: .leading)
                    TextField("1–31", text: $dayText).textFieldStyle(.roundedBorder).frame(width: 60)
                        .onSubmit { commit() }
                        .accessibilityIdentifier("an.detail.date.day")
                    Button("Set") { commit() }
                        .disabled(!dayFieldCommittable)
                }
                if let msg = impossibleDayMessage {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("an.detail.date.dayWarning")
                    }
                    .padding(.leading, 54)
                }
            }

            Toggle("Date uncertain (shown in italics)", isOn: uncertainBinding)
                .accessibilityIdentifier("an.detail.date.uncertain")
        }
    }

    // MARK: Quality

    @ViewBuilder private var qualitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quality").font(.subheadline.bold())
            QualityFacetRow(quality: item.quality) { q in
                let id = item.id
                Task { await nav.setQuality(q, for: id) }
            }
        }
    }

    // MARK: State ⇄ store

    /// Seed the local fields from the selected item's stored date (no write — see the type doc).
    private func seed(from item: ItemSummary) {
        precision = item.datePrecision ?? .year
        let parts = (item.date ?? "").split(separator: "-").map(String.init)
        yearText = parts.first ?? ""
        month = parts.count >= 2 ? (Int(parts[1]) ?? 0) : 0
        dayText = parts.count >= 3 ? parts[2] : ""
    }

    /// Why a typed day is being dropped (nil when there is nothing to report) — see `DateFieldEntry`.
    private var impossibleDayMessage: String? {
        DateFieldEntry.impossibleDayNote(yearText: yearText, month: month, dayText: dayText)
    }

    private var dayFieldCommittable: Bool {
        DateFieldEntry.dayCommittable(yearText: yearText, month: month, dayText: dayText)
    }

    /// The loose date string the fields describe; the model normalizes it (zero-pads, floors a decade,
    /// downgrades when a component is missing or impossible). `nil` ⟹ clear the date.
    private func composedDate() -> String? {
        DateFieldEntry.composed(yearText: yearText, month: month, dayText: dayText, precision: precision)
    }

    private func commit() {
        let date = composedDate()
        let p = precision
        let id = item.id
        Task { await nav.setDate(date, precision: p, for: id) }
    }

    // Bindings whose setters fire ONLY on user interaction (not on the programmatic `seed`), so
    // selecting an item never triggers a spurious write.
    private var precisionBinding: Binding<Item.DatePrecision> {
        Binding(get: { precision }, set: { precision = $0; commit() })
    }
    private var monthBinding: Binding<Int> {
        Binding(get: { month }, set: { month = $0; commit() })
    }
    private var uncertainBinding: Binding<Bool> {
        Binding(get: { item.dateUncertain },
                set: { v in let id = item.id; Task { await nav.setDateUncertain(v, for: id) } })
    }
}
