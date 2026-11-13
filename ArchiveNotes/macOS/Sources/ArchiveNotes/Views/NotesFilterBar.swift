import SwiftUI
import AppKit
import ArchiveCoreUI

/// The item-list filter bar (06-viewers §4, W6-S4). Binds a per-window `NotesNavigationModel` and
/// surfaces the kind segmented control, quality (Q1–Q3) toggles, a tag filter with chips (every tag must match), a
/// Dates button whose popover holds the year range, Save as Smart Folder / Clear All, a keyword search field (drives
/// FTS — bm25 relevance, as-you-type) with Advanced…, and the In effect row of chips. Matching any tag rather than
/// all of them belongs to Advanced Search (`NotesAdvancedSearchSheet`), not this bar (owner, notes-1 row 37, as
/// ruled for the Reader on 2026-11-04). The shared folder/smart-folder SCOPE comes from the tree
/// (`NotesModel.scope`) and is merged with this window's filter at `recompute()`.
///
/// It is laid out as the Reader's bar is, from the same pieces (W40.suite-reader-notes-consistency; owner, Notes
/// session 2 row 21: "the filtering UI should match the Reader's"): what the notes are on the first row, in a
/// `FilterBarLayout` that moves a control to the next row when it does not fit without rebuilding the field being
/// typed in, Save as Smart Folder and Clear All at its right; the search on the second; In effect under them.
/// The kind control stands where the Reader's read state does. Save stays shown with nothing else in effect, since a
/// window's kind alone is worth saving (a Notes-only smart folder, W9.d9).
struct NotesFilterBar: View {
    @ObservedObject var nav: NotesNavigationModel

    @State private var pendingTag = ""
    @State private var showingSaveSheet = false
    @State private var showingDateFilter = false
    @State private var smartFolderName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FilterBarLayout(spacing: 12) {
                kindPicker
                qualityToggles
                tagFilter
                datesButton
                saveButton.filterBarTrailing()
                clearAllButton.filterBarTrailing()
            }
            searchRow
            // Round-up is not a filter here (owner, notes-2 row 19): it is set in the inspector and searched
            // in Advanced Search, whose chip still shows in the row below.
            let chips = nav.activeFilterChips
            if !chips.isEmpty { activeFilterChipRow(chips) }
        }
        .padding(8)
        .sheet(isPresented: $showingSaveSheet) {
            NameEntrySheet(title: "Save as Smart Folder",
                           message: "Saves the current filters and keyword as a reusable smart folder.",
                           confirmLabel: "Save", name: $smartFolderName,
                           onConfirm: { name in
                               smartFolderName = ""
                               Task { await nav.saveAsSmartFolder(named: name) }
                           },
                           onCancel: { smartFolderName = "" })
        }
    }

    // MARK: Row 1 — kind · quality · tags · dates; Save / Clear All at the right

    private var kindPicker: some View {
        Picker("Kind", selection: $nav.kindFilter) {
            Text("All").tag(KindFilter.all)
            Text("Notes").tag(KindFilter.notes)
            Text("Extracts").tag(KindFilter.extracts)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("Filter the list by kind")
        .accessibilityIdentifier("an.filter.kind")
    }

    /// Q1 → Q3 toggle buttons binding `filter.qualities`, as the Reader's (the quality is the same 1–3 in both apps).
    private var qualityToggles: some View {
        HStack(spacing: 4) {
            ForEach([1, 2, 3], id: \.self) { q in
                Toggle("Q\(q)", isOn: Binding(
                    get: { nav.filter.qualities.contains(q) },
                    set: { on in
                        if on { nav.filter.qualities.insert(q) } else { nav.filter.qualities.remove(q) }
                    }))
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Show only items at quality Q\(q)")
                .accessibilityIdentifier("an.filter.quality.\(q)")
            }
        }
        .fixedSize()   // squeezed, the toggles collapse to "…" pills
    }

    /// The chosen tags as the Reader's chips, wrapping inside the field's width, and the suite's tag field after
    /// them (W40.fix-notes-tag-fields; owner session notes-2 row 20). Bounded like the Reader's tag filter, so it
    /// gives way first in a narrow list and moves to a row of its own rather than squeezing the field.
    private var tagFilter: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: "tag").foregroundStyle(.secondary).frame(height: 22)
                .accessibilityHidden(true)
            NoteTagChipsField(tags: $nav.filter.tags, draft: $pendingTag, placeholder: "Filter by tag…",
                              identifier: "an.filter.tagInput", chipIdentifier: "an.filter.tagChip",
                              suggestions: { NoteTagChipsField.suggestions(in: nav.model.allItems) })
        }
        .frame(minWidth: NoteTagChipsField.fieldWidth + 24, idealWidth: 260, maxWidth: 360, alignment: .leading)
        .help("Filter by tag — type to autocomplete the tags on notes; Return adds it; ✕ removes it")
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("an.filter.tags")
    }

    /// The Reader's compact Dates button; the year range is in its popover, and the button shows it once set.
    private var datesButton: some View {
        Button { showingDateFilter = true } label: {
            if let years = nav.filter.dateYearsSummary {
                Label(years, systemImage: "calendar")
            } else {
                Label("Dates", systemImage: "calendar").labelStyle(.iconOnly)
            }
        }
        .controlSize(.small)
        .fixedSize()
        .help("Filter by year")
        .accessibilityIdentifier("an.filter.dates")
        .popover(isPresented: $showingDateFilter) { dateFilterPopover }
    }

    private var saveButton: some View {
        Button("Save as Smart Folder") {
            smartFolderName = ""
            showingSaveSheet = true
        }
        .fixedSize()
        .help("Save these filters as a smart folder in the sidebar")
        .accessibilityIdentifier("an.filter.save")
    }

    private var clearAllButton: some View {
        Button("Clear All") {
            nav.clearAll()
            pendingTag = ""
        }
        .fixedSize()
        .disabled(!nav.canClearAll && pendingTag.isEmpty)
        .help(nav.clearAllHelp)
        .accessibilityIdentifier("an.filter.clear")
    }

    private var dateFilterPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Year range").font(.headline)
            HStack(spacing: 4) {
                TextField("From", text: fromYearText)
                    .accessibilityLabel("From year")
                    .accessibilityIdentifier("an.filter.dateFrom")
                Text("\u{2013}").foregroundStyle(.secondary)
                    .accessibilityHidden(true)   // decorative: the fields are named From year and To year
                TextField("To", text: toYearText)
                    .accessibilityLabel("To year")
                    .accessibilityIdentifier("an.filter.dateTo")
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            Text("Matches a note's own date or the date of the letter it was sent with.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Clear") { nav.clearDateFilter() }
                    .disabled(!nav.hasDateFilter)
                    .help("Clear the date filter")
                    .accessibilityIdentifier("an.filter.dateClear")
                Spacer()
                Button("Done") { showingDateFilter = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(12).frame(width: 220)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Row 2 — the search, Advanced…, the count

    /// The keyword search on its own row, a size larger, as the Reader's OCR search (W40.fix-reader-filter-bar).
    private var searchRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(nav.searchText.isEmpty ? Color.secondary : Color.accentColor)
                .accessibilityHidden(true)
            TextField("Search notes…", text: $nav.searchText)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(minWidth: 160, idealWidth: 320, maxWidth: 380)
                .help("Search the notes' titles and text")
                .accessibilityLabel("Search notes")
                .accessibilityIdentifier("an.filter.search")
            if !nav.searchText.isEmpty {
                Button { nav.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Clear the search")
                .accessibilityIdentifier("an.filter.searchClear")
            }
            Button("Advanced\u{2026}") { nav.openAdvancedSearch() }
                .fixedSize()
                .help("Advanced Search: rules for text, title, tags, kind, quality, dates and folders (⇧⌥⌘F)")
                .accessibilityIdentifier("an.filter.advanced")
            Spacer(minLength: 8)
            Text("\(nav.displayed.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
                .fixedSize()
                .help("Items shown")
                .accessibilityIdentifier("an.filter.count")
        }
    }

    /// Every filter and search in effect, each a chip whose ✕ removes it: the Reader's In effect row
    /// (W40.fix-notes-clear-all-advanced). An Advanced Search run without saving leads it, with Edit… beside
    /// it, so a list narrowed by one says so (owner, notes-2 row 26).
    private func activeFilterChipRow(_ chips: [NotesActiveFilterChip]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("In effect:").foregroundStyle(.secondary).font(.callout)
                .accessibilityHidden(true)
            FlowLayout(spacing: 6, lineSpacing: 4) {
                ForEach(chips) { chip in
                    ActiveFilterChipView(label: chip.label, phrase: chip.phrase,
                                         identifier: chip.accessibilityIdentifier) {
                        nav.removeFilter(chip.facet)
                    }
                    if chip.facet == .advancedSearch {
                        Button("Edit\u{2026}") { nav.openAdvancedSearch() }
                            .controlSize(.small)
                            .help("Edit the Advanced Search's rules")
                            .accessibilityIdentifier("an.filter.advancedEdit")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters in effect")
        .accessibilityIdentifier("an.filter.chips")
    }

    // MARK: Actions + derived bindings

    /// Year ⇆ sortDate int, derived straight from the filter (so Clear resets the field). The lower
    /// bound is the year's start (`year*10000`), matching a year-only item's sortDate so it's included.
    private var fromYearText: Binding<String> {
        Binding(
            get: { nav.filter.dateFrom.map { String($0 / 10000) } ?? "" },
            set: { newValue in
                if let year = Int(newValue.filter(\.isNumber)), year > 0 {
                    nav.filter.dateFrom = year * 10000
                } else {
                    nav.filter.dateFrom = nil
                }
            }
        )
    }

    /// The upper bound is the year's end (`year*10000 + 1231`) so the whole "to" year is inclusive.
    private var toYearText: Binding<String> {
        Binding(
            get: { nav.filter.dateTo.map { String($0 / 10000) } ?? "" },
            set: { newValue in
                if let year = Int(newValue.filter(\.isNumber)), year > 0 {
                    nav.filter.dateTo = year * 10000 + 1231
                } else {
                    nav.filter.dateTo = nil
                }
            }
        )
    }
}
