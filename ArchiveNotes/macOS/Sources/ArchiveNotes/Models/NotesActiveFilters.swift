// NotesActiveFilters.swift — what is in effect, as removable chips (W40.fix-notes-clear-all-advanced)
//
// The owner ran an Advanced Search, pressed Clear All and found the search still narrowing the list, with
// nothing plain to say so (notes-2 row 26). The Reader's answer is its In effect row
// (`ArchiveReader/.../Core/ActiveFilters.swift`): every filter and search in effect is a chip whose ✕ turns
// it off. This is the same row for Notes, pure and UI-free so the wording is a tested function. The kind
// control is always visible on the bar, so it is never a chip.

import Foundation

/// One thing in effect that narrows the list.
enum NotesFilterFacet: Hashable, Sendable {
    case advancedSearch, smartFolder, quality(Int), tag(String), dates, roundup, keyword
}

struct NotesActiveFilterChip: Identifiable, Equatable, Sendable {
    let facet: NotesFilterFacet
    /// What the chip shows: "Tag: budget".
    let label: String
    /// The same thing inside a sentence: "the tag “budget”".
    let phrase: String
    var id: NotesFilterFacet { facet }

    /// `an.filter.chip.<kind>`.
    var accessibilityIdentifier: String {
        switch facet {
        case .advancedSearch: return "an.filter.chip.advancedSearch"
        case .smartFolder: return "an.filter.chip.smartFolder"
        case let .quality(q): return "an.filter.chip.quality.\(q)"
        case let .tag(t): return "an.filter.chip.tag.\(t)"
        case .dates: return "an.filter.chip.dates"
        case .roundup: return "an.filter.chip.roundup"
        case .keyword: return "an.filter.chip.keyword"
        }
    }

    /// Every filter and search in effect, in the bar's order: where the list looks (an unsaved Advanced Search
    /// or a smart folder, whose rules keep narrowing it), then the filter bar, then the search box.
    /// `advancedSearch` is the unsaved search's rules, nil when the scope is not one.
    static func chips(filter f: NotesFilter, keyword: String, advancedSearch: NotesAdvancedSearch?,
                      smartFolderName: String?) -> [NotesActiveFilterChip] {
        var chips: [NotesActiveFilterChip] = []
        func add(_ facet: NotesFilterFacet, _ label: String, _ phrase: String) {
            chips.append(NotesActiveFilterChip(facet: facet, label: label, phrase: phrase))
        }
        if let search = advancedSearch {
            let n = search.rules.filter(\.isActive).count
            let rules = n == 1 ? "1 rule" : "\(n) rules"
            add(.advancedSearch, "Advanced Search: \(rules)", "the Advanced Search (\(rules))")
        }
        if let name = smartFolderName {
            add(.smartFolder, "Smart folder: \(name)", "the smart folder \u{201c}\(name)\u{201d}")
        }
        for q in f.qualities.sorted(by: >) { add(.quality(q), "\u{2605}\(q)", "the quality \(q) filter") }
        let anyOf = f.tags.count > 1 && f.tagCombine == .any
        for t in f.tags.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            add(.tag(t), anyOf ? "Tag (any): \(t)" : "Tag: \(t)", "the tag \u{201c}\(t)\u{201d}")
        }
        if let years = f.dateYearsSummary {
            let sent = f.dateRangeRoles == .own ? "" : f.dateRangeRoles == .sentWith ? ", sent-with date" : ", own or sent-with"
            add(.dates, "Years\(sent): \(years)", "the year range \(years)")
        }
        switch f.roundup {
        case nil: break
        case true?: add(.roundup, "Round-up notes", "the round-up notes filter")
        case false?: add(.roundup, "Other items", "the other-items filter")
        }
        let titled = f.searchText.trimmingCharacters(in: .whitespaces)
        if !titled.isEmpty { add(.keyword, "Title: \(titled)", "the title filter \u{201c}\(titled)\u{201d}") }
        let q = keyword.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, titled.isEmpty {
            add(.keyword, "Search: \u{201c}\(q)\u{201d}", "the search \u{201c}\(q)\u{201d}")
        }
        return chips
    }
}

extension NotesFilter {
    /// "1950–1960", "from 1950", "to 1960", or nil when no year bound is set.
    var dateYearsSummary: String? {
        switch (dateFrom.map { $0 / 10000 }, dateTo.map { $0 / 10000 }) {
        case (nil, nil): return nil
        case let (from?, to?): return from == to ? "\(from)" : "\(from)\u{2013}\(to)"
        case let (from?, nil): return "from \(from)"
        case let (nil, to?): return "to \(to)"
        }
    }

    /// This filter without one of its facets. The Advanced Search, the smart folder and the search box live
    /// outside the filter; for the search box, its durable title substring is dropped here too.
    func removing(_ facet: NotesFilterFacet) -> NotesFilter {
        var f = self
        switch facet {
        case .advancedSearch, .smartFolder: break
        case let .quality(q): f.qualities.remove(q)
        case let .tag(t): f.tags.removeAll { $0 == t }
        case .dates: f.dateFrom = nil; f.dateTo = nil; f.dateRangeRole = .own
        case .roundup: f.roundup = nil
        case .keyword: f.searchText = ""
        }
        return f
    }
}
