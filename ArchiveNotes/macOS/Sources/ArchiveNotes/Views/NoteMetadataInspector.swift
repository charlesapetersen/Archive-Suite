import SwiftUI
import ArchiveCore

/// The detail-pane **metadata strip** for the selected note/extract: edit authors, document DATE
/// (precision + precision-appropriate fields + a "date uncertain" toggle), and QUALITY. These fields
/// use front matter through `NotesNavigationModel` → `NotesModel`; authors remain front-matter only,
/// while the model mirrors valid Quality values as Q1...Q3 on this note's own `.md`. Its Tags subsection
/// uses the audited model path, so front matter remains authoritative and Finder subjects stay in sync.
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
    @EnvironmentObject private var sourcePreview: SourceBlockPreviewState
    @AppStorage(DisplayCalendarSettings.enabledKey) private var calendarsEnabled = false

    @State private var precision: Item.DatePrecision = .year
    @State private var yearText = ""
    @State private var month = 0          // 0 = none
    @State private var dayText = ""
    /// The calendar the date fields are typed in (W24.cal1-validator) — `DateFieldEntry.seed`.
    @State private var entryCalendar: DisplayCalendar = .standard
    // W37.dual-date: the covering letter's ("sent with") date — same field idiom, separate state, so
    // the two dates' components can never cross-pair.
    @State private var swPrecision: Item.DatePrecision = .year
    @State private var swYearText = ""
    @State private var swMonth = 0        // 0 = none
    @State private var swDayText = ""
    @State private var swEntryCalendar: DisplayCalendar = .standard
    @State private var authorsText = ""
    @State private var extractSources: [ExtractSourceUsage]?
    @State private var extractSourcesFailed = false
    @State private var roundupYear: Int?

    private struct SourceLoadKey: Equatable {
        let id: UUID
        let mtime: Double
    }

    private struct RoundupLoadKey: Equatable {
        let source: SourceLoadKey
        let archiveAccessRevision: UInt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if item.kind == .extract {
                extractSourcesSection
                Divider()
            } else {
                roundupSection
                Divider()
            }
            authorsSection
            Divider()
            dateSection
            Divider()
            qualitySection
            Divider()
            NoteTagsInspector(model: nav.model, item: item)
                .id(item.id)
            Divider()
            NoteZoteroInspector(model: nav.model, itemID: item.id)
                .id(item.id)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { seed(from: item) }
        .onChange(of: item.id) { seed(from: item) }   // re-seed only on selection change (WYSIWYG typing)
        // …or when the calendar the fields are typed in changes (the stored date does not).
        .onChange(of: activeCalendar) { seedDates(from: item) }
        .task(id: SourceLoadKey(id: item.id, mtime: item.mtime)) {
            extractSources = nil
            extractSourcesFailed = false
            guard item.kind == .extract else { return }
            let loaded = await nav.model.loadExtractSources(for: item.id)
            guard !Task.isCancelled else { return }
            extractSources = loaded
            extractSourcesFailed = loaded == nil
        }
        .task(id: RoundupLoadKey(source: SourceLoadKey(id: item.id, mtime: item.mtime),
                                archiveAccessRevision: sourcePreview.archiveAccessRevision)) {
            roundupYear = nil
            guard item.kind == .note, item.roundup,
                  let links = await nav.model.loadRoundupSourceLinks(for: item.id) else { return }
            let year = await sourcePreview.roundupYear(for: links)
            guard !Task.isCancelled else { return }
            roundupYear = year
        }
    }

    private var roundupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Round-up note", isOn: Binding(get: { item.roundup }, set: { value in
                let id = item.id
                Task { await nav.setRoundup(value, for: id) }
            }))
            .accessibilityIdentifier("an.detail.roundup")
            if item.roundup, let year = roundupYear,
               item.date != String(year) || item.datePrecision != .year {
                Text("Linked PDFs share the year \(String(year)).")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use \(String(year)) as note date") {
                    precision = .year
                    entryCalendar = .standard   // a year is always Gregorian
                    yearText = String(year)
                    month = 0
                    dayText = ""
                    commit()
                }
                .accessibilityIdentifier("an.detail.roundup.useYear")
            }
        }
    }

    // MARK: Extract provenance

    private var extractSourcesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Sources").font(.subheadline.bold())
                    .accessibilityIdentifier("an.detail.sources.heading")
                Spacer()
                if let extractSources {
                    Text("\(extractSources.count) note\(extractSources.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let extractSources {
                if extractSources.isEmpty {
                    Text("No note passages yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(extractSources) { source in
                    let resolved = sourceDisplay(source)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolved.title)
                                .lineLimit(2)
                                .accessibilityLabel(resolved.title)
                                .accessibilityIdentifier("an.detail.sources.note.\(source.id.uuidString).title")
                            if resolved.missing {
                                Text("Source note missing")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("\(source.passageCount) passage\(source.passageCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize()
                            .accessibilityIdentifier("an.detail.sources.note.\(source.id.uuidString).count")
                    }
                }
            } else if extractSourcesFailed {
                Text("Sources could not be loaded.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView("Loading sources…").controlSize(.small)
            }
        }
    }

    private func sourceDisplay(_ source: ExtractSourceUsage) -> (title: String, missing: Bool) {
        if let live = nav.model.allItems.first(where: { $0.id == source.id && $0.kind == .note }) {
            return (live.title.isEmpty ? "Untitled note" : live.title, false)
        }
        return (source.snapshotLabel ?? "Unknown source note", true)
    }

    // MARK: Authors

    @ViewBuilder private var authorsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Authors").font(.subheadline.bold())
                .accessibilityIdentifier("an.detail.authors.heading")
            TextField("One author per line", text: $authorsText, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("an.detail.authors")
            HStack {
                Button("Set") { commitAuthors() }
                    .disabled(composedAuthors == item.authors)
                    .accessibilityIdentifier("an.detail.authors.set")
                Button("Clear") {
                    authorsText = ""
                    commitAuthors([])
                }
                .disabled(item.authors.isEmpty && composedAuthors.isEmpty)
                .accessibilityIdentifier("an.detail.authors.clear")
            }
        }
    }

    // MARK: Date

    @ViewBuilder private var dateSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Date").font(.subheadline.bold())
                .accessibilityIdentifier("an.detail.metadata")
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
                Button("Clear") {
                    entryCalendar = DateFieldEntry.seed(storedDate: nil, active: activeCalendar,
                                                        precision: precision).calendar
                    yearText = ""; month = 0; dayText = ""; commit(.write(nil))
                }
            }

            if precision == .month || precision == .day {
                HStack {
                    Text("Month").frame(width: 54, alignment: .leading)
                    Picker("", selection: monthBinding) {
                        Text("—").tag(0)
                        ForEach(DateFieldEntry.monthChoices(yearText: yearText, calendar: entryCalendar),
                                id: \.month) { c in Text(c.name).tag(c.month) }
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
                if let msg = DateFieldEntry.incompleteNote(yearText: yearText, month: month, dayText: dayText,
                                                           calendar: entryCalendar) {
                    Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("an.detail.date.incomplete")
                }
                if let note = Self.entryNote(entryCalendar, active: activeCalendar) {
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("an.detail.date.entryCalendar")
                }
            }

            Toggle("Date uncertain (shown in italics)", isOn: uncertainBinding)
                .accessibilityIdentifier("an.detail.date.uncertain")

            if calendarsEnabled { calendarSection }

            sentWithSection
        }
    }

    /// W24.cal1-toggle: which calendar this item's day-precision dates are shown in. Only offered while
    /// Settings ▸ "Show dates in other calendars" is on. Choosing one never changes the stored date.
    @ViewBuilder private var calendarSection: some View {
        HStack {
            Text("Calendar").frame(width: 54, alignment: .leading)
            Picker("Display calendar", selection: displayCalendarBinding) {
                ForEach(DisplayCalendarSettings.choices, id: \.self) { cal in
                    Text(cal.displayName).tag(cal)
                }
            }
            .labelsHidden().frame(width: 220)
            .accessibilityIdentifier("an.detail.date.calendar")
        }
        if let note = calendarNote {
            Text(note)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("an.detail.date.calendarShown")
        }
    }

    /// "Shown as …" under the picker, or why the stored date is shown instead.
    private var calendarNote: String? {
        guard let cal = item.activeCalendar(calendarsEnabled: true) else { return nil }
        guard let date = item.date else { return nil }
        guard item.datePrecision == .day else {
            return "Only a full day (year, month and day) is shown in \(cal.displayName)."
        }
        if let shown = DisplayCalendarSettings.shown(isoDay: date, in: cal) { return "Shown as \(shown)." }
        return "This date is outside the \(cal.displayName) calendar; shown as stored."
    }

    /// The covering letter's date (W37.dual-date): an item enclosed with a dated letter keeps its own
    /// date above and records the letter's here. Sorting uses the own date and falls back to this one
    /// only when there is no own date — said explicitly below so the fallback is never mistaken for
    /// the item's own date.
    @ViewBuilder private var sentWithSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sent with").font(.subheadline.bold())
                .accessibilityIdentifier("an.detail.sentWith.heading")
            Picker("Sent-with precision", selection: swPrecisionBinding) {
                Text("Decade").tag(Item.DatePrecision.decade)
                Text("Year").tag(Item.DatePrecision.year)
                Text("Month").tag(Item.DatePrecision.month)
                Text("Day").tag(Item.DatePrecision.day)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("an.detail.sentWith.precision")

            HStack {
                Text(swPrecision == .decade ? "Decade" : "Year").frame(width: 54, alignment: .leading)
                TextField(swPrecision == .decade ? "e.g. 1950" : "e.g. 1958", text: $swYearText)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                    .onSubmit { commitSentWith() }
                    .accessibilityIdentifier("an.detail.sentWith.year")
                Button("Set") { commitSentWith() }
                    .disabled((Int(swYearText.trimmingCharacters(in: .whitespaces)) ?? 0) <= 0)
                Button("Clear") {
                    swEntryCalendar = DateFieldEntry.seed(storedDate: nil, active: activeCalendar,
                                                          precision: swPrecision).calendar
                    swYearText = ""; swMonth = 0; swDayText = ""; commitSentWith(.write(nil))
                }
                    .disabled(item.sentWith == nil)
            }

            if swPrecision == .month || swPrecision == .day {
                HStack {
                    Text("Month").frame(width: 54, alignment: .leading)
                    Picker("", selection: swMonthBinding) {
                        Text("—").tag(0)
                        ForEach(DateFieldEntry.monthChoices(yearText: swYearText, calendar: swEntryCalendar),
                                id: \.month) { c in Text(c.name).tag(c.month) }
                    }
                    .labelsHidden().frame(width: 150)
                    .accessibilityIdentifier("an.detail.sentWith.month")
                }
            }

            if swPrecision == .day {
                HStack {
                    Text("Day").frame(width: 54, alignment: .leading)
                    TextField("1–31", text: $swDayText).textFieldStyle(.roundedBorder).frame(width: 60)
                        .onSubmit { commitSentWith() }
                        .accessibilityIdentifier("an.detail.sentWith.day")
                    Button("Set") { commitSentWith() }
                        .disabled(!DateFieldEntry.dayCommittable(yearText: swYearText, month: swMonth,
                                                                 dayText: swDayText, calendar: swEntryCalendar))
                }
                if let msg = DateFieldEntry.impossibleDayNote(yearText: swYearText, month: swMonth,
                                                              dayText: swDayText, calendar: swEntryCalendar) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("an.detail.sentWith.dayWarning")
                    }
                    .padding(.leading, 54)
                }
                if let msg = DateFieldEntry.incompleteNote(yearText: swYearText, month: swMonth,
                                                           dayText: swDayText, calendar: swEntryCalendar) {
                    Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let note = Self.entryNote(swEntryCalendar, active: activeCalendar) {
                    Text(note)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle("Sent-with date uncertain", isOn: sentWithUncertainBinding)
                .disabled(item.sentWith == nil)
                .accessibilityIdentifier("an.detail.sentWith.uncertain")

            if let sent = item.displaySentWith(calendarsEnabled: calendarsEnabled) {
                Text(item.sortsBySentWith
                     ? "Sent with: \(sent) — sorted by this date (no own date)."
                     : "Sent with: \(sent)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("an.detail.sentWith.summary")
            }
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

    /// Seed local fields from the selected item's stored authors and date (no write — see the type doc).
    private func seed(from item: ItemSummary) {
        authorsText = item.authors.joined(separator: "\n")
        seedDates(from: item)
    }

    /// Seed both dates' fields, each in the calendar it is typed in (`DateFieldEntry.seed`).
    private func seedDates(from item: ItemSummary) {
        precision = item.datePrecision ?? .year
        let active = item.activeCalendar(calendarsEnabled: calendarsEnabled)
        let own = DateFieldEntry.seed(storedDate: item.date, active: active, precision: precision)
        (yearText, month, dayText) = (own.fields.yearText, own.fields.month, own.fields.dayText)
        entryCalendar = own.calendar
        let sent = item.sentWith.map(Item.frontMatterDate)
        swPrecision = sent?.precision ?? .year
        let sw = DateFieldEntry.seed(storedDate: sent?.date, active: active, precision: swPrecision)
        (swYearText, swMonth, swDayText) = (sw.fields.yearText, sw.fields.month, sw.fields.dayText)
        swEntryCalendar = sw.calendar
    }

    private var activeCalendar: DisplayCalendar? { item.activeCalendar(calendarsEnabled: calendarsEnabled) }

    /// Under the day row: which calendar the fields are typed in, when one other than Gregorian is in
    /// play. A stored date that is not a whole day is entered in Gregorian even with a calendar chosen.
    private static func entryNote(_ entry: DisplayCalendar, active: DisplayCalendar?) -> String? {
        if entry != .standard {
            return "Entered in the \(entry.displayName) calendar; only a whole day is stored, as its Gregorian day."
        }
        guard let active, active != .standard else { return nil }
        return "Entered in Gregorian: when selected, the item held no whole day \(active.displayName) can show. Clear the date to enter one in \(active.displayName)."
    }

    /// Why a typed day is being dropped (nil when there is nothing to report) — see `DateFieldEntry`.
    private var impossibleDayMessage: String? {
        DateFieldEntry.impossibleDayNote(yearText: yearText, month: month, dayText: dayText,
                                         calendar: entryCalendar)
    }

    private var dayFieldCommittable: Bool {
        DateFieldEntry.dayCommittable(yearText: yearText, month: month, dayText: dayText,
                                      calendar: entryCalendar)
    }

    /// What the fields commit; the model normalizes a written date (zero-pads, floors a decade,
    /// downgrades when a component is missing or impossible). `.write(nil)` ⟹ clear the date.
    private func composedDate() -> DateFieldEntry.Commit {
        DateFieldEntry.commit(yearText: yearText, month: month, dayText: dayText, precision: precision,
                              calendar: entryCalendar, storedDate: item.date)
    }

    private func commit(_ value: DateFieldEntry.Commit? = nil) {
        guard case .write(let date) = value ?? composedDate() else { return }
        let p = precision
        let id = item.id
        Task { await nav.setDate(date, precision: p, for: id) }
    }

    private func commitSentWith(_ value: DateFieldEntry.Commit? = nil) {
        let stored = item.sentWith.map(Item.frontMatterDate)?.date
        guard case .write(let date) = value ?? DateFieldEntry.commit(
            yearText: swYearText, month: swMonth, dayText: swDayText, precision: swPrecision,
            calendar: swEntryCalendar, storedDate: stored) else { return }
        // A precision/month change with no year typed and nothing stored is not an edit.
        if date == nil && item.sentWith == nil { return }
        let p = swPrecision
        let id = item.id
        Task { await nav.setSentWith(date, precision: p, for: id) }
    }

    private var composedAuthors: [String] {
        authorsText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func commitAuthors(_ authors: [String]? = nil) {
        let value = authors ?? composedAuthors
        let id = item.id
        Task { await nav.setAuthors(value, for: id) }
    }

    // Bindings whose setters fire ONLY on user interaction (not on the programmatic `seed`), so
    // selecting an item never triggers a spurious write.
    private var precisionBinding: Binding<Item.DatePrecision> {
        Binding(get: { precision }, set: { new in
            // Composed in the calendar the fields are typed in. Moving into or out of a calendar (it
            // applies at day precision only) re-shows the date in the new one — the date being
            // written, or the stored one when the calendar fields commit nothing, which is then
            // committed at the new precision from its Gregorian fields.
            var value = DateFieldEntry.commit(yearText: yearText, month: month, dayText: dayText,
                                              precision: new, calendar: entryCalendar)
            precision = new
            if DateFieldEntry.entryCalendar(activeCalendar, precision: new) != entryCalendar {
                let shown: String? = if case .write(let d) = value { d } else { item.date }
                let s = DateFieldEntry.seed(storedDate: shown, active: activeCalendar, precision: new)
                (yearText, month, dayText) = (s.fields.yearText, s.fields.month, s.fields.dayText)
                entryCalendar = s.calendar
                if value == .keep {
                    value = DateFieldEntry.commit(yearText: yearText, month: month, dayText: dayText,
                                                  precision: new, calendar: entryCalendar)
                }
            }
            commit(value)
        })
    }
    private var monthBinding: Binding<Int> {
        Binding(get: { month }, set: { month = $0; commit() })
    }
    private var swPrecisionBinding: Binding<Item.DatePrecision> {
        Binding(get: { swPrecision }, set: { new in
            var value = DateFieldEntry.commit(yearText: swYearText, month: swMonth, dayText: swDayText,
                                              precision: new, calendar: swEntryCalendar)
            swPrecision = new
            if DateFieldEntry.entryCalendar(activeCalendar, precision: new) != swEntryCalendar {
                let stored = item.sentWith.map(Item.frontMatterDate)?.date
                let shown: String? = if case .write(let d) = value { d } else { stored }
                let s = DateFieldEntry.seed(storedDate: shown, active: activeCalendar, precision: new)
                (swYearText, swMonth, swDayText) = (s.fields.yearText, s.fields.month, s.fields.dayText)
                swEntryCalendar = s.calendar
                if value == .keep {
                    value = DateFieldEntry.commit(yearText: swYearText, month: swMonth, dayText: swDayText,
                                                  precision: new, calendar: swEntryCalendar)
                }
            }
            commitSentWith(value)
        })
    }
    private var swMonthBinding: Binding<Int> {
        Binding(get: { swMonth }, set: { swMonth = $0; commitSentWith() })
    }
    private var sentWithUncertainBinding: Binding<Bool> {
        Binding(get: { item.sentWithUncertain },
                set: { v in let id = item.id; Task { await nav.setSentWithUncertain(v, for: id) } })
    }
    private var displayCalendarBinding: Binding<DisplayCalendar> {
        Binding(get: { item.displayCalendar ?? .standard },
                set: { v in let id = item.id; Task { await nav.setDisplayCalendar(v, for: id) } })
    }
    private var uncertainBinding: Binding<Bool> {
        Binding(get: { item.dateUncertain },
                set: { v in let id = item.id; Task { await nav.setDateUncertain(v, for: id) } })
    }
}
