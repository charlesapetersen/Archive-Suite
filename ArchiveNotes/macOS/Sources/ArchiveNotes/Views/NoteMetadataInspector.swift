import SwiftUI
import ArchiveCore

/// The **inspector panel**'s fields for the selected note/extract (W40.notes-detail-layout): Round-up or
/// Sources, authors, document DATE (one typed field + a "date uncertain" toggle), QUALITY, the item's
/// folder locations and Zotero. These fields use front matter through `NotesNavigationModel` →
/// `NotesModel`; authors remain front-matter only, while the model mirrors valid Quality values as Q1...Q3
/// on this note's own `.md`. Tags are edited in the tag bar under the note (`NoteTagBar`).
///
/// Adapted from Reader's `InlineEditCells.DateCell` + `TagEditorView.dateSection`/`prioritySection`,
/// retargeted from tag writes to the Notes front-matter store. Local field state is seeded from the
/// selected `ItemSummary` on selection change. A date field applies on Return or on leaving it, at the
/// precision typed, and an emptied one clears the date (W40.fix-notes-date-entry: no Set, Clear or
/// precision picker) — never on the programmatic seed, so selecting an item never rewrites its date.
/// Each edit calls the async setter, which normalizes (`Item.normalizedDate`: decade floors the year;
/// month/day downgrade when a lower field is missing), persists atomically, and re-indexes.
///
/// The field rules — how typed text is read, what a commit composes, and the note shown for a day
/// the month cannot have (`Feb 31`, W23.l4) — live in `DateFieldEntry` so they are unit-testable
/// without a window; this view is the `@State` layer over them.
struct NoteMetadataInspector: View {
    @ObservedObject var nav: NotesNavigationModel
    let item: ItemSummary
    @EnvironmentObject private var sourcePreview: SourceBlockPreviewState
    @AppStorage(DisplayCalendarSettings.enabledKey) private var calendarsEnabled = false

    @State private var dateText = ""
    /// The calendar the date field is typed in (W24.cal1-validator) — `DateFieldEntry.seedText`.
    @State private var entryCalendar: DisplayCalendar = .standard
    // W37.dual-date: the covering letter's ("sent with") date — same field idiom, separate state.
    @State private var swDateText = ""
    @State private var swEntryCalendar: DisplayCalendar = .standard
    /// Which item each field's text belongs to and the text last applied there, so leaving a field
    /// writes only a real edit, and only to the item it was typed for — even when the selection has
    /// already moved on.
    @State private var dateApplied = AppliedText()
    @State private var swApplied = AppliedText()
    @FocusState private var focusedDate: DateRole?
    @State private var authorsText = ""
    @State private var extractSources: [ExtractSourceUsage]?
    @State private var extractSourcesFailed = false
    @State private var roundupYear: Int?

    private enum DateRole: Hashable { case own, sentWith }

    private struct AppliedText {
        var id: UUID?
        var text = ""
        var stored: String?
    }

    private struct StoredDates: Equatable {
        let date: String?
        let precision: Item.DatePrecision?
        let sentWith: ArchiveDate?
        init(_ item: ItemSummary) {
            (date, precision, sentWith) = (item.date, item.datePrecision, item.sentWith)
        }
    }

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
            // In the inspector rather than above the note (W40.notes-detail-layout, notes-1 row 32).
            LocationsInspector(nav: nav, itemId: item.id)
            Divider()
            NoteZoteroInspector(model: nav.model, itemID: item.id)
                .id(item.id)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { seed(from: item) }
        .onChange(of: item.id) {   // re-seed only on selection change (WYSIWYG typing)…
            applyDates()           // …after a field still being typed in reaches its own item
            seed(from: item)
        }
        // …or when the calendar the fields are typed in changes (the stored date does not).
        .onChange(of: activeCalendar) {
            applyDates()
            seedDates(from: item)
        }
        // The list's Date cell edits the same dates (W40.notes-detail-layout): show a date changed there, unless one
        // of the fields is being typed in or holds text not applied yet, which a reseed would throw away.
        .onChange(of: StoredDates(item)) {
            guard focusedDate == nil, dateText == dateApplied.text, swDateText == swApplied.text else { return }
            seedDates(from: item)
        }
        .onChange(of: focusedDate) { old, _ in
            if old == .own { applyDate() }
            if old == .sentWith { applySentWith() }
        }
        .onDisappear { applyDates() }
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

    /// What a round-up note is and what marking one does (`00-overview.md` §3.5).
    static let roundupExplanation = "For a note that gathers several loosely related documents, usually from one "
        + "year. Marked, it can be found with the filter bar's Round-up menu, and when its linked PDFs share a "
        + "year, Notes offers that year as the note's date."

    private var roundupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Round-up note", isOn: Binding(get: { item.roundup }, set: { value in
                let id = item.id
                Task { await nav.setRoundup(value, for: id) }
            }))
            .help(Self.roundupExplanation)
            .accessibilityIdentifier("an.detail.roundup")
            // Said where it is turned on: the owner could not tell what the toggle did (notes-1, row 24).
            Text(Self.roundupExplanation)
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("an.detail.roundup.explanation")
            if item.roundup, let year = roundupYear,
               item.date != String(year) || item.datePrecision != .year {
                Text("Linked PDFs share the year \(String(year)).")
                    .font(.caption).foregroundStyle(.primary)
                Button("Use \(String(year)) as note date") {
                    entryCalendar = .standard   // a year is always Gregorian
                    dateText = String(year)
                    applyDate()
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
                        .font(.caption).foregroundStyle(.primary)
                }
            }
            if let extractSources {
                if extractSources.isEmpty {
                    Text("No note passages yet.").font(.caption).foregroundStyle(.primary)
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
                                    .font(.caption2).foregroundStyle(.primary)
                            }
                        }
                        Spacer(minLength: 4)
                        Text("\(source.passageCount) passage\(source.passageCount == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.primary)
                            .fixedSize()
                            .accessibilityIdentifier("an.detail.sources.note.\(source.id.uuidString).count")
                    }
                }
            } else if extractSourcesFailed {
                Text("Sources could not be loaded.").font(.caption).foregroundStyle(.primary)
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
                .accessibilityLabel("Authors")
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
            TextField("e.g. 1968, 1960s, March 1968, 12 March 1968", text: $dateText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                .focused($focusedDate, equals: .own)
                .onSubmit { applyDate() }
                .accessibilityLabel("Date")
                .accessibilityIdentifier("an.detail.date.field")
            dateMessages(text: dateText, calendar: entryCalendar, id: "an.detail.date")
            if let shown = item.displayDate(calendarsEnabled: calendarsEnabled), let p = item.datePrecision {
                Text("Saved as \(shown) (\(p.rawValue)).")
                    .font(.caption).foregroundStyle(.primary)
                    .accessibilityIdentifier("an.detail.date.saved")
            }

            Toggle("Date uncertain (shown in italics)", isOn: uncertainBinding)
                .accessibilityIdentifier("an.detail.date.uncertain")

            if calendarsEnabled { calendarSection }

            sentWithSection
        }
    }

    /// What a typed date field needs to say: why the text cannot be read, why a day is dropped, why a
    /// calendar entry is not saved yet, and which calendar the field is typed in.
    @ViewBuilder private func dateMessages(text: String, calendar: DisplayCalendar, id: String) -> some View {
        let (typed, calendar) = DateFieldEntry.resolve(text, calendar: calendar)
        switch typed {
        case .unreadable(let why):
            Text(why).font(.caption).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(id).unreadable")
        case .date(let f, _):
            if let msg = DateFieldEntry.impossibleDayNote(yearText: f.yearText, month: f.month,
                                                          dayText: f.dayText, calendar: calendar) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("\(id).dayWarning")
                }
            }
            if let msg = DateFieldEntry.incompleteNote(yearText: f.yearText, month: f.month,
                                                       dayText: f.dayText, calendar: calendar) {
                Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(id).incomplete")
            }
        case .empty:
            EmptyView()
        }
        if let note = Self.entryNote(DateFieldEntry.resolve(text, calendar: calendar).calendar,
                                     active: activeCalendar) {
            Text(note)
                .font(.caption).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(id).entryCalendar")
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
                .font(.caption).foregroundStyle(.primary)
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
            TextField("e.g. 1958, March 1958, 12 March 1958", text: $swDateText)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                .focused($focusedDate, equals: .sentWith)
                .onSubmit { applySentWith() }
                .accessibilityLabel("Sent-with date")
                .accessibilityIdentifier("an.detail.sentWith.field")
            dateMessages(text: swDateText, calendar: swEntryCalendar, id: "an.detail.sentWith")

            Toggle("Sent-with date uncertain", isOn: sentWithUncertainBinding)
                .disabled(item.sentWith == nil)
                .accessibilityIdentifier("an.detail.sentWith.uncertain")

            if let sent = item.displaySentWith(calendarsEnabled: calendarsEnabled) {
                Text(item.sortsBySentWith
                     ? "Sent with: \(sent) — sorted by this date (no own date)."
                     : "Sent with: \(sent)")
                    .font(.caption).foregroundStyle(.primary)
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

    /// Seed both date fields, each in the calendar it is typed in (`DateFieldEntry.seedText`).
    private func seedDates(from item: ItemSummary) {
        let active = item.activeCalendar(calendarsEnabled: calendarsEnabled)
        let own = DateFieldEntry.seedText(storedDate: item.date, precision: item.datePrecision, active: active)
        (dateText, entryCalendar) = (own.text, own.calendar)
        dateApplied = AppliedText(id: item.id, text: own.text, stored: item.date)
        let sent = item.sentWith.map(Item.frontMatterDate)
        let sw = DateFieldEntry.seedText(storedDate: sent?.date, precision: sent?.precision, active: active)
        (swDateText, swEntryCalendar) = (sw.text, sw.calendar)
        swApplied = AppliedText(id: item.id, text: sw.text, stored: sent?.date)
    }

    private var activeCalendar: DisplayCalendar? { item.activeCalendar(calendarsEnabled: calendarsEnabled) }

    /// Under the day row: which calendar the fields are typed in, when one other than Gregorian is in
    /// play. A stored date that is not a whole day is entered in Gregorian even with a calendar chosen.
    private static func entryNote(_ entry: DisplayCalendar, active: DisplayCalendar?) -> String? {
        if entry != .standard {
            return "A whole day is entered in the \(entry.displayName) calendar and stored as its Gregorian day; a year, month or decade is read as Gregorian."
        }
        guard let active, active != .standard else { return nil }
        return "Entered in Gregorian: when selected, the item held no whole day \(active.displayName) can show. Empty the field to enter one in \(active.displayName)."
    }

    private func applyDates() {
        applyDate()
        applySentWith()
    }

    /// Apply the typed own date to the item it was typed for, if it changed since it was last applied.
    private func applyDate() {
        guard let id = dateApplied.id, dateText != dateApplied.text else { return }
        let (typed, calendar) = DateFieldEntry.resolve(dateText, calendar: entryCalendar)
        let (value, precision) = DateFieldEntry.commit(typed: typed, calendar: calendar,
                                                       storedDate: dateApplied.stored)
        guard case .write(let date) = value else { return }
        dateApplied.text = dateText
        dateApplied.stored = date
        if date == nil {   // emptied: the next date is typed in the item's calendar again
            entryCalendar = DateFieldEntry.seedText(storedDate: nil, precision: nil, active: activeCalendar).calendar
        }
        Task { await nav.setDate(date, precision: precision, for: id) }
    }

    /// The same for the covering letter's date.
    private func applySentWith() {
        guard let id = swApplied.id, swDateText != swApplied.text else { return }
        let (typed, calendar) = DateFieldEntry.resolve(swDateText, calendar: swEntryCalendar)
        let (value, precision) = DateFieldEntry.commit(typed: typed, calendar: calendar,
                                                       storedDate: swApplied.stored)
        guard case .write(let date) = value else { return }
        let hadDate = swApplied.stored != nil
        swApplied.text = swDateText
        swApplied.stored = date
        if date == nil {
            swEntryCalendar = DateFieldEntry.seedText(storedDate: nil, precision: nil, active: activeCalendar).calendar
            guard hadDate else { return }   // emptying an empty field is not an edit
        }
        Task { await nav.setSentWith(date, precision: precision, for: id) }
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
