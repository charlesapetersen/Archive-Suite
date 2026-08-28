import SwiftUI
import AppKit

/// The item-list filter bar (06-viewers §4, W6-S4). Binds a per-window `NotesNavigationModel` and
/// surfaces the kind segmented control, a keyword search field (drives FTS — bm25 relevance,
/// as-you-type), quality (★1–★3) toggles, a tag filter with ALL/ANY combine + chips, a year date
/// range, and Save-as-Smart-Folder / Clear. The shared folder/smart-folder SCOPE comes from the tree
/// (`NotesModel.scope`) and is merged with this window's filter at `recompute()`.
///
/// Adapted from Reader's `NavigationWindowView.filterBar`; layout is two compact rows so all facets
/// stay visible at the browser's minimum width.
struct NotesFilterBar: View {
    @ObservedObject var nav: NotesNavigationModel

    @State private var pendingTag = ""
    @State private var showingSaveSheet = false
    @State private var smartFolderName = ""

    var body: some View {
        VStack(spacing: 6) {
            topRow
            facetRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .alert("Save as Smart Folder", isPresented: $showingSaveSheet) {
            TextField("Name", text: $smartFolderName)
            Button("Cancel", role: .cancel) { smartFolderName = "" }
            Button("Save") {
                let name = smartFolderName
                smartFolderName = ""
                Task { await nav.saveAsSmartFolder(named: name) }
            }
        } message: {
            Text("Saves the current filters and keyword as a reusable smart folder.")
        }
    }

    // MARK: Row 1 — kind · keyword · count · actions

    private var topRow: some View {
        HStack(spacing: 8) {
            Picker("Kind", selection: $nav.kindFilter) {
                Text("Notes").tag(KindFilter.notes)
                Text("Extracts").tag(KindFilter.extracts)
                Text("Both").tag(KindFilter.both)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("an.filter.kind")

            keywordField

            Text("\(nav.displayed.count)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
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

            Button("Clear") {
                nav.clearUserFilters()
                pendingTag = ""
            }
            .disabled(!hasClearableFilters)
            .accessibilityIdentifier("an.filter.clear")
        }
    }

    private var keywordField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search notes…", text: $nav.searchText)
                .textFieldStyle(.plain)
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
        .frame(minWidth: 160)
    }

    // MARK: Row 2 — quality · tags · date range

    private var facetRow: some View {
        HStack(spacing: 12) {
            qualityToggles
            Divider().frame(height: 16)
            tagFilter
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

    private var tagFilter: some View {
        HStack(spacing: 6) {
            Picker("", selection: $nav.filter.tagCombine) {
                Text("All").tag(TagCombine.all)
                Text("Any").tag(TagCombine.any)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Match all tags, or any tag")
            .accessibilityIdentifier("an.filter.tagCombine")

            TextField("Tag…", text: $pendingTag)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .onSubmit(addPendingTag)
                .accessibilityIdentifier("an.filter.tagInput")

            ForEach(nav.filter.tags, id: \.self) { tag in
                HStack(spacing: 2) {
                    Text(tag).font(.caption).lineLimit(1)
                    Button { nav.filter.tags.removeAll { $0 == tag } } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                .accessibilityIdentifier("an.filter.tagChip.\(tag)")
            }
        }
    }

    private var dateRange: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar").foregroundStyle(.secondary)
            TextField("From", text: fromYearText)
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .help("From year")
                .accessibilityIdentifier("an.filter.dateFrom")
            Text("–").foregroundStyle(.secondary)
            TextField("To", text: toYearText)
                .frame(width: 54)
                .textFieldStyle(.roundedBorder)
                .help("To year")
                .accessibilityIdentifier("an.filter.dateTo")
        }
    }

    // MARK: Actions + derived bindings

    private func addPendingTag() {
        let t = pendingTag.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTag = ""
        guard !t.isEmpty, !nav.filter.tags.contains(t) else { return }
        nav.filter.tags.append(t)
    }

    /// Something beyond the always-visible kind control is set (so Clear has an effect).
    private var hasClearableFilters: Bool {
        !nav.filter.qualities.isEmpty
            || !nav.filter.tags.isEmpty
            || nav.filter.dateFrom != nil
            || nav.filter.dateTo != nil
            || !nav.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
