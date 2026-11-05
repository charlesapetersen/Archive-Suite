import Foundation

// MARK: - What is in effect (W40.fix-reader-filter-bar)
//
// The owner searched a name, chose another folder in the tree and saw an empty list without noticing the
// search still applied (reader-1 row 8). Keeping the search is right; what is in effect has to be plain. So
// every filter and search in effect is a removable chip under the bar, and an empty list caused by one says
// which and offers to clear it. Pure and UI-free, so the wording is a tested function.

/// One thing in effect that narrows the list.
enum FilterFacet: Hashable, Sendable {
    case smartFolder, folder, read, quality(Int), tag(String), dates, name, text, needsAttention, ambiguousDates

    /// The folder and the smart folder say *where* the list looks rather than what it looks for, so an empty
    /// list is blamed on them only when no other filter alone explains it.
    var isLocation: Bool { self == .smartFolder || self == .folder }
}

struct ActiveFilterChip: Identifiable, Equatable, Sendable {
    let facet: FilterFacet
    /// What the chip shows: "Name: smith".
    let label: String
    /// The same thing inside a sentence: "the file-name filter “smith”".
    let phrase: String
    var id: FilterFacet { facet }

    /// `ar.filter.chip.<kind>`; the two health filters keep the identifiers their toggles had.
    var accessibilityIdentifier: String {
        switch facet {
        case .smartFolder: return "ar.filter.chip.smartFolder"
        case .folder: return "ar.filter.chip.folder"
        case .read: return "ar.filter.chip.read"
        case let .quality(q): return "ar.filter.chip.quality.Q\(q)"
        case let .tag(t): return "ar.filter.chip.tag.\(t)"
        case .dates: return "ar.filter.chip.dates"
        case .name: return "ar.filter.chip.name"
        case .text: return "ar.filter.chip.text"
        case .needsAttention: return "ar.filter.needsAttention"
        case .ambiguousDates: return "ar.filter.ambiguousDates"
        }
    }

    /// Every filter and search in effect, in the bar's order: where, then what the documents are, then what they
    /// contain. `fullTextQuery` is the OCR search only once it applies (its results are in), else nil.
    static func chips(filter f: LibraryFilter, smartFolderName: String?, fullTextQuery: String?) -> [ActiveFilterChip] {
        var chips: [ActiveFilterChip] = []
        func add(_ facet: FilterFacet, _ label: String, _ phrase: String) {
            chips.append(ActiveFilterChip(facet: facet, label: label, phrase: phrase))
        }
        if let name = smartFolderName { add(.smartFolder, "Smart folder: \(name)", "the smart folder \u{201c}\(name)\u{201d}") }
        if let p = f.pathPrefix, !p.isEmpty {
            let name = URL(fileURLWithPath: p).lastPathComponent
            add(.folder, "Folder: \(name)", "the folder \u{201c}\(name)\u{201d}")
        }
        switch f.read {
        case .all: break
        case .read: add(.read, "Read", "the Read filter")
        case .unread: add(.read, "Unread", "the Unread filter")
        case .noReadState: add(.read, "No read state", "the no-read-state filter")
        }
        for q in f.qualities.sorted() { add(.quality(q), "Q\(q)", "the Q\(q) filter") }
        let anyOf = f.subjects.count > 1 && f.subjectCombine == .any
        for t in f.subjects.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            add(.tag(t), anyOf ? "Tag (any): \(t)" : "Tag: \(t)", "the tag \u{201c}\(t)\u{201d}")
        }
        if let years = f.dateYearsSummary { add(.dates, "Years: \(years)", "the year range \(years)") }
        let name = f.searchText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { add(.name, "Name: \(name)", "the file-name filter \u{201c}\(name)\u{201d}") }
        if let q = fullTextQuery?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            add(.text, "Text: \u{201c}\(q)\u{201d}", "the OCR search \u{201c}\(q)\u{201d}")
        }
        if f.needsAttentionOnly { add(.needsAttention, "Needs attention", "the needs-attention filter") }
        if f.ambiguousDatesOnly { add(.ambiguousDates, "Ambiguous dates", "the ambiguous-dates filter") }
        return chips
    }

    /// The empty list's sentence. `causes` are the chips that, removed alone, would bring rows back.
    static func emptyExplanation(chips: [ActiveFilterChip], causes: [FilterFacet]) -> String {
        let blamed = chips.filter { causes.contains($0.facet) }
        // Where the list is looking, when that is not itself the cause: "in the folder “Brown”".
        let place = chips.first { $0.facet.isLocation && !causes.contains($0.facet) }
        let inPlace = place.map { " in \($0.phrase)" } ?? ""
        switch blamed.count {
        case 0:
            let what = chips.filter { !$0.facet.isLocation }.map(\.label)
            guard !what.isEmpty else { return "No files\(inPlace) to show." }
            return "No file\(inPlace) matches these together: \(what.joined(separator: " \u{b7} "))."
        case 1:
            return "\(capitalized(blamed[0].phrase)) hides every file\(inPlace)."
        default:
            return "Each of these hides every file\(inPlace): \(blamed.map(\.label).joined(separator: " \u{b7} "))."
        }
    }

    private static func capitalized(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

extension LibraryFilter {
    /// This filter without one of its facets. The smart folder and the OCR search live outside the filter, so
    /// for them it is unchanged.
    func removing(_ facet: FilterFacet) -> LibraryFilter {
        var f = self
        switch facet {
        case .smartFolder, .text: break
        case .folder: f.pathPrefix = nil
        case .read: f.read = .all
        case let .quality(q): f.qualities.remove(q)
        case let .tag(t): f.subjects.remove(t)
        case .dates: f.dateFromYear = nil; f.dateToYear = nil
        case .name: f.searchText = ""
        case .needsAttention: f.needsAttentionOnly = false
        case .ambiguousDates: f.ambiguousDatesOnly = false
        }
        return f
    }
}
