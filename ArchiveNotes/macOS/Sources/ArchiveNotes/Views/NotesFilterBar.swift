import SwiftUI
import AppKit

/// The item-list filter bar (06-viewers §4, W6-S4). Binds a per-window `NotesNavigationModel` and
/// surfaces the kind segmented control, a keyword search field (drives FTS — bm25 relevance,
/// as-you-type), quality (★1–★3) toggles, a tag filter with chips (every tag must match), a year date
/// range with its own clear button, and Save-as-Smart-Folder / Clear All. Matching any tag rather than
/// all of them belongs to Advanced Search (`NotesAdvancedSearchSheet`, the bar's Advanced Search button), not this bar (owner, notes-1
/// row 37, as ruled for the Reader on 2026-11-04). The shared folder/smart-folder SCOPE comes from the tree
/// (`NotesModel.scope`) and is merged with this window's filter at `recompute()`.
///
/// Adapted from Reader's `NavigationWindowView.filterBar`; layout is compact rows so all facets
/// stay visible at the browser's minimum width.
struct NotesFilterBar: View {
    @ObservedObject var nav: NotesNavigationModel

    @State private var pendingTag = ""
    @State private var showingSaveSheet = false
    @State private var smartFolderName = ""

    var body: some View {
        VStack(spacing: 6) {
            if nav.model.scopeIsUnsavedSearch { advancedScopeRow }
            topRow
            facetRow
            tagFilter
            HStack {
                Picker("Round-up", selection: $nav.filter.roundup) {
                    Text("Any").tag(Optional<Bool>.none)
                    Text("Round-up notes").tag(Optional(true))
                    Text("Other items").tag(Optional(false))
                }
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("an.filter.roundup")
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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

    // MARK: Row 1 — kind · keyword · count · actions

    private var topRow: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: $nav.kindFilter) {
                Text("All").tag(KindFilter.all)
                Text("Notes").tag(KindFilter.notes)
                Text("Extracts").tag(KindFilter.extracts)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("an.filter.kind")

            keywordField

            Button { nav.openAdvancedSearch() } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .help("Advanced Search: rules for text, title, authors, tags, kind, quality, dates and folders (⇧⌥⌘F)")
            .accessibilityLabel("Advanced Search")
            .accessibilityIdentifier("an.filter.advanced")

            Text("\(nav.displayed.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.primary)
                .help("Items shown")
                .accessibilityIdentifier("an.filter.count")

            Button {
                smartFolderName = ""
                showingSaveSheet = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("Save as Smart Folder")
            .accessibilityIdentifier("an.filter.save")

            Button("Clear All") {
                nav.clearUserFilters()
                pendingTag = ""
            }
            .disabled(!nav.hasUserFilters && pendingTag.isEmpty)
            .help("Clear every filter and the search")
            .accessibilityIdentifier("an.filter.clear")
        }
    }

    private var keywordField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes…", text: $nav.searchText)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search notes")
                .accessibilityIdentifier("an.filter.search")
            if !nav.searchText.isEmpty {
                Button { nav.searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("an.filter.searchClear")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
        .frame(minWidth: 120)   // so the row fits beside the Advanced Search button at the list's narrowest
    }

    /// Shown while the list is an Advanced Search run without saving, so it can be edited or left
    /// (W40.notes-advanced-search).
    private var advancedScopeRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
            Text("Advanced Search").font(.callout)
            Button("Edit\u{2026}") { nav.openAdvancedSearch() }
                .accessibilityIdentifier("an.filter.advancedEdit")
            Button("Show All Notes") { nav.model.setAllNotesScope() }
                .accessibilityIdentifier("an.filter.advancedDone")
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("an.filter.advancedScope")
    }

    // MARK: Row 2 — quality · date range; row 3 — tags

    private var facetRow: some View {
        HStack(spacing: 12) {
            qualityToggles
            Divider().frame(height: 16)
            dateRange
            Spacer(minLength: 0)
        }
    }

    /// ★3…★1 toggle row (highest first), binding `filter.qualities`. Structurally copied from Reader's
    /// priority toggles (`NavigationWindowView.swift:256-267`, there `[10,9,8,7]`).
    private var qualityToggles: some View {
        HStack(spacing: 2) {
            ForEach([3, 2, 1], id: \.self) { q in
                let on = nav.filter.qualities.contains(q)
                Button {
                    if on { nav.filter.qualities.remove(q) } else { nav.filter.qualities.insert(q) }
                } label: {
                    Image(systemName: on ? "star.fill" : "star")
                        .foregroundStyle(on ? Color.yellow : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Quality \(q)")
                .accessibilityIdentifier("an.filter.quality.\(q)")
            }
        }
    }

    /// Its own row, the width of the bar, so the field is big enough and the chips wrap
    /// (W40.fix-notes-tag-fields; owner session notes-2 row 20).
    private var tagFilter: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary).frame(height: 22)
                .accessibilityHidden(true)
            NoteTagChipsField(tags: $nav.filter.tags, draft: $pendingTag, placeholder: "Tag…",
                              identifier: "an.filter.tagInput", chipIdentifier: "an.filter.tagChip",
                              suggestions: { NoteTagChipsField.suggestions(in: nav.model.allItems) })
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dateRange: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            TextField("From", text: fromYearText)
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .help("From year")
                .accessibilityLabel("From year")
                .accessibilityIdentifier("an.filter.dateFrom")
            Text("–").foregroundStyle(.primary)
                .accessibilityHidden(true)   // decorative: the fields are named From year and To year
            TextField("To", text: toYearText)
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .help("To year")
                .accessibilityLabel("To year")
                .accessibilityIdentifier("an.filter.dateTo")
            if nav.hasDateFilter {
                Button { nav.clearDateFilter() } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the date filter")
                .accessibilityLabel("Clear the date filter")
                .accessibilityIdentifier("an.filter.dateClear")
            }
        }
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
