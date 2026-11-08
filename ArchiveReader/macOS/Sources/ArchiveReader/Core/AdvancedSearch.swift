import Foundation
import ArchiveCore

// MARK: - Advanced Search (W40.reader-advanced-search)
//
// `RuleCombine`, `RuleOperator`, `DateRoleChoice` and the text and date parsing are ArchiveCore's
// (`Search/AdvancedSearchRules.swift`), shared with Notes' Advanced Search (W40.notes-advanced-search).
//
// Finder-style rules: "all" or "any of the following rules", each row a field, an operator and a value, and a
// row may be a group with its own all/any. This is what a smart folder stores. Pure and UI-free: the text rules
// are answered by the content index (`ftsExpression`), whose hits the caller passes in as `RuleContext`; every
// other rule is an in-memory test of the file. Display/filter only — never drives a write.
//
// A rule with no value yet (an empty text box, no tags picked) is inactive and is skipped, so the starter rows
// change nothing until they are filled in. "has none of these tags" exists here only: the filter bar keeps its
// no-NOT rule (owner, 2026-11-04).

enum RuleField: String, Codable, Sendable, CaseIterable {
    /// OCR text, file name and classification: every column of the index ("Any text"). The Find box searches
    /// the OCR text alone, as `ocrText` does (W40.fix-reader-ocr-search-names).
    case text
    /// The OCR text alone (the index's body column).
    case ocrText
    /// The file name, as a substring (like the filter bar's name box), not through the index.
    case fileName
    case tags
    case quality
    case readState
    case date
    case folder
    case needsAttention
    case ambiguousDate
    case flagged
    /// A nested list of rules with its own all/any (`SearchRule.combine`, `children`).
    case group

    var isText: Bool { self == .text || self == .ocrText }

    /// What a row's `text` holds for this field; a field change to another kind clears it, so OCR words never
    /// become a folder path or a date.
    var textKind: Int {
        switch self {
        case .text, .ocrText, .fileName: return 0
        case .folder: return 1
        case .date: return 2
        default: return 3
        }
    }

    /// The operators a row for this field offers, the first being the default.
    var operators: [RuleOperator] {
        switch self {
        case .text, .ocrText: return [.allWords, .phrase, .anyWords, .noWords]
        case .fileName: return [.contains, .doesNotContain, .beginsWith, .endsWith]
        case .tags: return [.hasAll, .hasAny, .hasNone]
        case .quality, .readState, .folder: return [.is, .isNot]
        case .date: return [.between, .after, .before, .undated]
        case .needsAttention, .ambiguousDate, .flagged: return [.is, .isNot]
        case .group: return [.is]
        }
    }
}

/// One row. Which value fields it reads depends on `field`; the others keep their defaults, so a row whose field
/// is changed in the form keeps nothing stale that matters.
struct SearchRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var field: RuleField
    var op: RuleOperator
    /// Words or phrase (text fields), the name text (file name), the folder path, the "from" or only date.
    var text: String = ""
    /// The "to" date of `between`.
    var text2: String = ""
    var tags: [String] = []
    /// Quality levels 1–5; 0 stands for "no quality tag".
    var qualities: Set<Int> = []
    var read: ReadFilter = .unread
    var dateRole: DateRoleChoice = .either
    /// A group row's own all/any and rules.
    var combine: RuleCombine = .all
    var children: [SearchRule] = []

    init(field: RuleField, op: RuleOperator? = nil) {
        self.field = field
        self.op = op ?? field.operators[0]
    }

    /// Every key but the field is optional on decode, so a rule saved before a value field existed still loads
    /// (a smart folder that fails to decode would be lost from the store on its next save).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(RuleField.self, forKey: .field)
        op = try c.decodeIfPresent(RuleOperator.self, forKey: .op) ?? field.operators[0]
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        text2 = try c.decodeIfPresent(String.self, forKey: .text2) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        qualities = try c.decodeIfPresent(Set<Int>.self, forKey: .qualities) ?? []
        read = try c.decodeIfPresent(ReadFilter.self, forKey: .read) ?? .unread
        dateRole = try c.decodeIfPresent(DateRoleChoice.self, forKey: .dateRole) ?? .either
        combine = try c.decodeIfPresent(RuleCombine.self, forKey: .combine) ?? .all
        children = try c.decodeIfPresent([SearchRule].self, forKey: .children) ?? []
    }

    static func group(_ combine: RuleCombine, _ children: [SearchRule]) -> SearchRule {
        var r = SearchRule(field: .group); r.combine = combine; r.children = children
        return r
    }

    /// Whether the row has a value to test. An inactive row is skipped (it neither passes nor fails).
    var isActive: Bool {
        switch field {
        case .text, .ocrText: return !AdvancedSearch.words(text).isEmpty
        case .fileName: return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .folder: return !text.isEmpty
        case .tags: return !tags.isEmpty
        case .quality: return !qualities.isEmpty
        case .readState: return read != .all
        case .date: return op == .undated || dateBounds != nil
        case .needsAttention, .ambiguousDate, .flagged: return true
        case .group: return children.contains(where: \.isActive)
        }
    }

    /// A date rule's inclusive key bounds (`DocumentTags.sortDateKey` space), or nil while a value it needs is
    /// missing or unreadable. A year runs from its first to its last day, a month likewise.
    var dateBounds: DateRangeFilter? { AdvancedSearchText.dateBounds(op: op, from: text, to: text2) }

    /// The FTS5 expression whose hits a text rule needs, or nil for other rules. For `noWords` it is the files
    /// to leave out (any of the words).
    var ftsExpression: String? {
        guard field.isText, isActive else { return nil }
        let column = field == .ocrText ? "body" : nil
        return AdvancedSearch.ftsExpression(op: op, text: text, column: column)
    }
}

/// What the in-memory test cannot see on the file: the content index's answers.
struct RuleContext: Sendable {
    /// Per text rule id, the paths matching its `ftsExpression`. A text rule missing here (its query has not
    /// returned yet) is skipped like an inactive one.
    var textHits: [UUID: Set<String>] = [:]
    var needsAttention: Set<String> = []
    var flagged: Set<String> = []
}

struct AdvancedSearch: Codable, Equatable, Sendable {
    var combine: RuleCombine = .all
    var rules: [SearchRule] = []

    /// The form's opening rows (owner, 2026-11-04): OCR text, tags and a date, so it reads like sections at
    /// first. Empty, so they match everything until filled in.
    static var starter: AdvancedSearch {
        AdvancedSearch(combine: .all, rules: [SearchRule(field: .ocrText), SearchRule(field: .tags),
                                              SearchRule(field: .date)])
    }

    var isActive: Bool { rules.contains(where: \.isActive) }

    /// Every active text rule, groups included, for the caller to run through the index.
    var textRules: [SearchRule] {
        func walk(_ rules: [SearchRule]) -> [SearchRule] {
            rules.flatMap { $0.field == .group ? walk($0.children) : ($0.ftsExpression == nil ? [] : [$0]) }
        }
        return walk(rules)
    }

    var hasTextRules: Bool { !textRules.isEmpty }

    /// Whether an active rule, groups included, tests `field`.
    func uses(_ field: RuleField) -> Bool {
        func walk(_ rules: [SearchRule]) -> Bool {
            rules.contains { $0.isActive && ($0.field == field || ($0.field == .group && walk($0.children))) }
        }
        return walk(rules)
    }

    /// One expression for ranking and snippets: the positive text rules OR-ed. nil when there are none.
    var rankingExpression: String? {
        let parts = textRules.filter { $0.op != .noWords }.compactMap(\.ftsExpression)
        guard !parts.isEmpty else { return nil }
        return parts.count == 1 ? parts[0] : parts.map { "(\($0))" }.joined(separator: " OR ")
    }

    func matches(_ file: ArchiveFile, _ context: RuleContext) -> Bool {
        Self.evaluate(rules, combine, file, context)
    }

    private static func evaluate(_ rules: [SearchRule], _ combine: RuleCombine, _ file: ArchiveFile,
                                 _ context: RuleContext) -> Bool {
        var anyTested = false
        for rule in rules {
            guard let result = test(rule, file, context) else { continue }
            anyTested = true
            if combine == .all, !result { return false }
            if combine == .any, result { return true }
        }
        return combine == .all || !anyTested
    }

    /// nil = the rule is skipped (inactive, or its index answer has not arrived).
    private static func test(_ rule: SearchRule, _ file: ArchiveFile, _ context: RuleContext) -> Bool? {
        guard rule.isActive else { return nil }
        let positive = rule.op != .isNot
        switch rule.field {
        case .text, .ocrText:
            guard let hits = context.textHits[rule.id] else { return nil }
            return rule.op == .noWords ? !hits.contains(file.path) : hits.contains(file.path)
        case .fileName:
            let q = rule.text.trimmingCharacters(in: .whitespaces)
            let opts: String.CompareOptions = [.caseInsensitive]   // as the filter bar's name box
            switch rule.op {
            case .doesNotContain: return file.name.range(of: q, options: opts) == nil
            case .beginsWith: return file.name.range(of: q, options: opts.union(.anchored)) != nil
            case .endsWith: return file.name.range(of: q, options: opts.union([.anchored, .backwards])) != nil
            default: return file.name.range(of: q, options: opts) != nil
            }
        case .tags:
            switch rule.op {
            case .hasAny: return rule.tags.contains(where: file.hasSubject)
            case .hasNone: return !rule.tags.contains(where: file.hasSubject)
            default: return rule.tags.allSatisfy(file.hasSubject)
            }
        case .quality:
            return rule.qualities.contains(file.quality ?? 0) == positive
        case .readState:
            let state: Bool
            switch rule.read {
            case .all: return nil
            case .read: state = file.readState == .read
            case .unread: state = file.readState == .unread
            case .noReadState: state = file.readState == nil
            }
            return state == positive
        case .date:
            return AdvancedSearchText.dateMatches(op: rule.op, bounds: rule.dateBounds, role: rule.dateRole,
                                                  keys: file.tags.dateKeysByRole)
        case .folder:
            let dir = rule.text.hasSuffix("/") ? String(rule.text.dropLast()) : rule.text
            return (file.path == dir || file.path.hasPrefix(dir + "/")) == positive
        case .needsAttention: return context.needsAttention.contains(file.path) == positive
        case .ambiguousDate: return file.dateIsAmbiguous == positive
        case .flagged: return context.flagged.contains(file.path) == positive
        case .group: return evaluate(rule.children, rule.combine, file, context)
        }
    }

    // MARK: Text and dates (shared with Notes: ArchiveCore `AdvancedSearchText`)

    static func words(_ text: String) -> [String] { AdvancedSearchText.words(text) }

    static func ftsExpression(op: RuleOperator, text: String, column: String?) -> String? {
        AdvancedSearchText.ftsExpression(op: op, text: text, column: column)
    }

    static func dateKeys(_ text: String) -> (lower: Int, upper: Int)? { AdvancedSearchText.dateKeys(text) }
}

// MARK: - From the filter bar

extension AdvancedSearch {
    /// The rules that say what a filter-bar state and Find query say, for saving it as a smart folder. The Find
    /// box's own rule is kept: its last word matches as a prefix when longer than two characters.
    init(filter f: LibraryFilter, fullTextQuery: String) {
        var rules: [SearchRule] = []
        let findWords = AdvancedSearch.words(fullTextQuery)
        if !findWords.isEmpty {
            var r = SearchRule(field: .ocrText, op: .allWords)   // the box searches the OCR text alone
            var ws = findWords
            if let last = ws.last, last.count > 2, !last.hasSuffix("*") { ws[ws.count - 1] = last + "*" }
            r.text = ws.joined(separator: " ")
            rules.append(r)
        }
        if let p = f.pathPrefix, !p.isEmpty {
            var r = SearchRule(field: .folder); r.text = p; rules.append(r)
        }
        if !f.subjects.isEmpty {
            var r = SearchRule(field: .tags, op: f.subjectCombine == .any ? .hasAny : .hasAll)
            r.tags = f.subjects.sorted(); rules.append(r)
        }
        if !f.qualities.isEmpty {
            var r = SearchRule(field: .quality); r.qualities = f.qualities; rules.append(r)
        }
        if f.read != .all {
            var r = SearchRule(field: .readState); r.read = f.read; rules.append(r)
        }
        if f.dateRange != nil {
            var r = SearchRule(field: .date, op: .between)
            r.text = f.dateFromYear.map(String.init) ?? ""
            r.text2 = f.dateToYear.map(String.init) ?? ""
            rules.append(r)
        }
        let name = f.searchText.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            var r = SearchRule(field: .fileName); r.text = name; rules.append(r)
        }
        if f.needsAttentionOnly { rules.append(SearchRule(field: .needsAttention)) }
        if f.ambiguousDatesOnly { rules.append(SearchRule(field: .ambiguousDate)) }
        self.init(combine: .all, rules: rules)
    }

    /// `self` narrowed by `more`: both must match. Flat when `self` is "all", else `self` becomes a group.
    func narrowed(by more: AdvancedSearch) -> AdvancedSearch {
        guard more.isActive else { return self }
        guard isActive else { return more }
        let mine = combine == .all ? rules : [SearchRule.group(combine, rules)]
        let theirs = more.combine == .all ? more.rules : [SearchRule.group(more.combine, more.rules)]
        return AdvancedSearch(combine: .all, rules: mine + theirs)
    }

    /// The rules with every folder rule outside `rootPath` dropped (groups included), and whether any was.
    func droppingFolders(outside rootPath: String?) -> (search: AdvancedSearch, dropped: Bool) {
        var dropped = false
        func clean(_ rules: [SearchRule]) -> [SearchRule] {
            rules.compactMap { r in
                if r.field == .group { var g = r; g.children = clean(r.children); return g }
                guard r.field == .folder, !r.text.isEmpty,
                      NavigationModel.sanitizedPathPrefix(r.text, against: rootPath) == nil else { return r }
                dropped = true
                return nil
            }
        }
        return (AdvancedSearch(combine: combine, rules: clean(rules)), dropped)
    }
}
