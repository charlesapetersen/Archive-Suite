import SwiftUI
import ArchiveCore

/// The Processor's one typed date field (W40.processor-date-field): the suite design from ArchiveCore `DateFieldEntry`,
/// as Notes' inspector has it. The precision is the one typed — `1960s`, `1968`, `March 1968`, `12 March 1968` or
/// `1968-03-12` — so there are no separate year, month and day controls. What can be read is written to `date` as it
/// is typed (a Save without leaving the field keeps it); text that cannot be read writes nothing, sets `unreadable`
/// so the caller refuses to save, and says why under the field. An impossible day is dropped to its month, and said.
///
/// `date` may also change from outside (an auto-date reply, the next segment): the field then shows the new value.
struct TypedDateField: View {
    let label: String
    @Binding var date: ArchiveDate?
    @Binding var unreadable: Bool
    /// Shown when `date` is nil but the stored strings are not empty (`TypedDateTags.rawText`).
    var fallbackText: String = ""
    var read: (String) -> DateFieldEntry.Reading = DateFieldEntry.archiveDate
    var placeholder = "e.g. 1968, 1960s, March 1968, 12 March 1968"
    var width: CGFloat = 230
    var focusOnAppear = false
    var accessibilityID: String

    @State private var text = ""
    /// The last value this field wrote, so a change to `date` that is not its own reseeds the text.
    @State private var written: ArchiveDate?? = .none
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.primary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder).frame(width: width)
                .focused($focused)
                .accessibilityLabel(label)
                .accessibilityIdentifier(accessibilityID)
            message
        }
        .onAppear {
            seed()
            if focusOnAppear { focused = true }
        }
        .onChange(of: text) { _, new in apply(new) }
        .onChange(of: date) { _, new in
            if written != .some(new) { seed() }
        }
        // Stored text that names no date can arrive after this field appeared (a parent's onAppear seeds it).
        .onChange(of: fallbackText) { _, _ in
            if date == nil { seed() }
        }
    }

    @ViewBuilder private var message: some View {
        switch read(text) {
        case .unreadable(let why):
            Label(why + " It will not be saved.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(accessibilityID).unreadable")
        case .date(let d, let note):
            if let note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("\(accessibilityID).dayWarning")
            } else {
                Text("\(label): \(d.display)").font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityID).reads")
            }
        case .empty:
            EmptyView()
        }
    }

    private func seed() {
        written = .some(date)
        text = date?.wireValue ?? fallbackText
        apply(text)
    }

    private func apply(_ value: String) {
        switch read(value) {
        case .empty:
            unreadable = false
            write(nil)
        case .date(let d, _):
            unreadable = false
            write(d)
        case .unreadable:
            unreadable = true
        }
    }

    private func write(_ d: ArchiveDate?) {
        written = .some(d)
        if date != d { date = d }
    }
}

/// The covering letter's date (W37.dual-date), a level below the item's own Date and folded away unless there is
/// one, as in Notes' inspector (W40.suite-date-design): few items came enclosed with a letter.
struct SentWithDateSection<Proposal: View>: View {
    /// The `ArchiveDate` wire value; empty = none.
    @Binding var sentWith: String
    @Binding var uncertain: Bool
    @Binding var unreadable: Bool
    /// What an empty field means here, said under the explanation.
    var emptyMeaning: String = "Leave it empty for an item that was not enclosed with a letter."
    var startsExpanded = false
    @ViewBuilder var proposal: () -> Proposal

    @State private var expanded = false

    private var date: Binding<ArchiveDate?> {
        Binding(get: { ArchiveDate.parse(wireValue: sentWith.trimmingCharacters(in: .whitespaces)) },
                set: { sentWith = $0?.wireValue ?? "" })
    }

    var body: some View {
        // Never folded away while its text cannot be read: that text is what keeps Save disabled.
        DisclosureGroup(isExpanded: Binding(get: { expanded || unreadable }, set: { expanded = $0 })) {
            VStack(alignment: .leading, spacing: 6) {
                Text("The date of the letter this item was sent with, for an item that came enclosed with one. The Date above stays the item's own date. \(emptyMeaning)")
                    .font(.caption2).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                proposal()
                TypedDateField(label: "Sent with", date: date, unreadable: $unreadable,
                               fallbackText: date.wrappedValue == nil ? sentWith : "",
                               width: 200, accessibilityID: "ap.date.sentWith")
                Toggle("Sent-with date uncertain", isOn: $uncertain)
                    .accessibilityIdentifier("ap.date.sentWith.uncertain")
            }
            .padding(.top, 4)
        } label: {
            // The heading opens and closes it too, not only the chevron.
            Button { expanded.toggle() } label: {
                Text(date.wrappedValue.map { "Sent with a letter: \($0.display)" } ?? "Sent with a letter")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("The date of the letter this item was sent with, for an item that came enclosed with one")
            .accessibilityIdentifier("ap.date.sentWith.heading")
        }
        // No identifier on the group: SwiftUI stamps it on every child, hiding the field's own.
        .onAppear { expanded = startsExpanded || !sentWith.isEmpty || unreadable }
    }
}

extension SentWithDateSection where Proposal == EmptyView {
    init(sentWith: Binding<String>, uncertain: Binding<Bool>, unreadable: Binding<Bool>,
         emptyMeaning: String = "Leave it empty for an item that was not enclosed with a letter.") {
        self.init(sentWith: sentWith, uncertain: uncertain, unreadable: unreadable,
                  emptyMeaning: emptyMeaning, startsExpanded: false, proposal: { EmptyView() })
    }
}
