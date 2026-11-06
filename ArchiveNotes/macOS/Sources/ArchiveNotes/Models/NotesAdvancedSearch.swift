// NotesAdvancedSearch.swift — Notes' Advanced Search: Finder-style rule rows (W40.notes-advanced-search).
//
// The Reader's design (W40.reader-advanced-search, owner 2026-11-04; asked for Notes in guided session notes-1,
// row 37): "all" or "any of the following rules", each row a field, an operator and a value, and a row may be a
// group with its own all/any. This is what a smart folder stores (`VFolder.queryJSON`). The combine, the
// operators, the date roles and the text/date parsing are ArchiveCore's (`Search/AdvancedSearchRules.swift`),
// shared with the Reader; the fields are Notes' own.
//
// Pure and UI-free: text rules are answered by the disposable FTS index (`ftsExpression`), folder rules by the
// organization graph, and both answers come in as `NotesRuleContext`; every other rule tests the `ItemSummary`.
// A rule with no value yet is inactive and skipped, so the starter rows change nothing until they are filled in.
// "has none of these tags" and "has any of these tags" exist here only: the filter bar ANDs its tags and keeps
// no NOT (owner, notes-1 row 37, as ruled for the Reader on 2026-11-04).

import Foundation
import ArchiveCore

enum NotesRuleField: String, Codable, Sendable, CaseIterable {
    /// Title, tags, authors and body: the columns the filter bar's search box searches.
    case text
    /// The note's body alone (the index's `body` column).
    case noteText
    /// The title as a substring, not through the index.
    case title
    case authors
    case tags
    case kind
    case quality
    case date
    case uncertainDate
    case folder
    case roundup
    /// A nested list of rules with its own all/any (`NotesSearchRule.combine`, `children`).
    case group

    var isText: Bool { self == .text || self == .noteText }

    /// What a row's `text` holds for this field; a field change to another kind clears it, so note words never
    /// become tags or a date.
    var textKind: Int {
        switch self {
        case .text, .noteText, .title, .authors: return 0
        case .tags: return 1
        case .date: return 2
        default: return 3
        }
    }

    /// The operators a row for this field offers, the first being the default.
    var operators: [RuleOperator] {
        switch self {
        case .text, .noteText: return [.allWords, .phrase, .anyWords, .noWords]
        case .title: return [.contains, .doesNotContain, .beginsWith, .endsWith]
        case .authors: return [.contains, .doesNotContain]
        case .tags: return [.hasAll, .hasAny, .hasNone]
        case .date: return [.between, .after, .before, .undated]
        case .kind, .quality, .uncertainDate, .folder, .roundup: return [.is, .isNot]
        case .group: return [.is]
        }
    }
}

/// One row. Which value fields it reads depends on `field`; the others keep their defaults.
struct NotesSearchRule: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var field: NotesRuleField
    var op: RuleOperator
    /// Words or phrase (text fields), the title or author text, tags separated by commas, the "from" or only date.
    var text: String = ""
    /// The "to" date of `between`.
    var text2: String = ""
    var kind: Item.Kind = .note
    /// Quality levels 1–3; 0 stands for "no quality".
    var qualities: Set<Int> = []
    var dateRole: DateRoleChoice = .either
    /// A folder rule's folder: membership in it or any folder below it (graph, not path).
    var folderId: UUID?
    /// A group row's own all/any and rules.
    var combine: RuleCombine = .all
    var children: [NotesSearchRule] = []

    init(field: NotesRuleField, op: RuleOperator? = nil) {
        self.field = field
        self.op = op ?? field.operators[0]
    }

    /// Every key but the field is optional on decode, so a rule saved before a value field existed still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        field = try c.decode(NotesRuleField.self, forKey: .field)
        op = try c.decodeIfPresent(RuleOperator.self, forKey: .op) ?? field.operators[0]
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        text2 = try c.decodeIfPresent(String.self, forKey: .text2) ?? ""
        kind = try c.decodeIfPresent(Item.Kind.self, forKey: .kind) ?? .note
        qualities = try c.decodeIfPresent(Set<Int>.self, forKey: .qualities) ?? []
        dateRole = try c.decodeIfPresent(DateRoleChoice.self, forKey: .dateRole) ?? .either
        folderId = try c.decodeIfPresent(UUID.self, forKey: .folderId)
        combine = try c.decodeIfPresent(RuleCombine.self, forKey: .combine) ?? .all
        children = try c.decodeIfPresent([NotesSearchRule].self, forKey: .children) ?? []
    }

    static func group(_ combine: RuleCombine, _ children: [NotesSearchRule]) -> NotesSearchRule {
        var r = NotesSearchRule(field: .group); r.combine = combine; r.children = children
        return r
    }

    static func folder(_ id: UUID) -> NotesSearchRule {
        var r = NotesSearchRule(field: .folder); r.folderId = id
        return r
    }

    /// The tags of a tags row: its text split on commas, trimmed, empty pieces dropped.
    var tagList: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether the row has a value to test. An inactive row is skipped (it neither passes nor fails).
    var isActive: Bool {
        switch field {
        case .text, .noteText: return !AdvancedSearchText.words(text).isEmpty
        case .title, .authors: return !text.trimmingCharacters(in: .whitespaces).isEmpty
        case .tags: return !tagList.isEmpty
        case .quality: return !qualities.isEmpty
        case .date: return op == .undated || dateBounds != nil
        case .folder: return folderId != nil
        case .kind, .uncertainDate, .roundup: return true
        case .group: return children.contains(where: \.isActive)
        }
    }

    var dateBounds: DateRangeFilter? { AdvancedSearchText.dateBounds(op: op, from: text, to: text2) }

    /// The FTS5 expression whose hits a text rule needs, or nil for other rules. For `noWords` it is the items
    /// to leave out (any of the words).
    var ftsExpression: String? {
        guard field.isText, isActive else { return nil }
        return AdvancedSearchText.ftsExpression(op: op, text: text, column: field == .noteText ? "body" : nil)
    }
}

/// What the in-memory test cannot see on the item: the index's and the folder graph's answers.
struct NotesRuleContext: Sendable {
    /// Per text rule id, the items matching its `ftsExpression`. A text rule missing here (its query has not
    /// returned yet) is skipped like an inactive one.
    var textHits: [UUID: Set<UUID>] = [:]
    /// Per folder id, the items in it or any folder below it. A folder missing here holds nothing.
    var folderItems: [UUID: Set<UUID>] = [:]
}

struct NotesAdvancedSearch: Codable, Equatable, Sendable {
    var combine: RuleCombine = .all
    var rules: [NotesSearchRule] = []

    /// The form's opening rows, as the Reader's (owner, 2026-11-04): text, tags and a date. Empty, so they match
    /// everything until filled in.
    static var starter: NotesAdvancedSearch {
        NotesAdvancedSearch(combine: .all, rules: [NotesSearchRule(field: .text), NotesSearchRule(field: .tags),
                                                   NotesSearchRule(field: .date)])
    }

    /// A normal folder's scope: the items in it or below it.
    static func folderScope(_ id: UUID) -> NotesAdvancedSearch {
        NotesAdvancedSearch(combine: .all, rules: [.folder(id)])
    }

    init(combine: RuleCombine = .all, rules: [NotesSearchRule] = []) {
        self.combine = combine
        self.rules = rules
    }

    /// Both keys optional on decode, as each rule's are; a rule with an unknown field still fails, so a smart
    /// folder that cannot be read says so rather than matching everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        combine = try c.decodeIfPresent(RuleCombine.self, forKey: .combine) ?? .all
        rules = try c.decodeIfPresent([NotesSearchRule].self, forKey: .rules) ?? []
    }

    var isActive: Bool { rules.contains(where: \.isActive) }

    /// Every active text rule, groups included, for the caller to run through the index.
    var textRules: [NotesSearchRule] {
        func walk(_ rules: [NotesSearchRule]) -> [NotesSearchRule] {
            rules.flatMap { $0.field == .group ? walk($0.children) : ($0.ftsExpression == nil ? [] : [$0]) }
        }
        return walk(rules)
    }

    var hasTextRules: Bool { !textRules.isEmpty }

    /// Every folder an active folder rule names, groups included.
    var folderIDs: Set<UUID> {
        func walk(_ rules: [NotesSearchRule]) -> [UUID] {
            rules.flatMap { r -> [UUID] in
                if r.field == .group { return walk(r.children) }
                return r.field == .folder && r.isActive ? [r.folderId!] : []
            }
        }
        return Set(walk(rules))
    }

    /// The folder a plain folder scope names (`folderScope`), else nil.
    var plainFolderScope: UUID? {
        guard combine == .all, rules.count == 1, rules[0].field == .folder, rules[0].op == .is else { return nil }
        return rules[0].folderId
    }

    func matches(_ item: ItemSummary, _ context: NotesRuleContext) -> Bool {
        Self.evaluate(rules, combine, item, context)
    }

    private static func evaluate(_ rules: [NotesSearchRule], _ combine: RuleCombine, _ item: ItemSummary,
                                 _ context: NotesRuleContext) -> Bool {
        var anyTested = false
        for rule in rules {
            guard let result = test(rule, item, context) else { continue }
            anyTested = true
            if combine == .all, !result { return false }
            if combine == .any, result { return true }
        }
        return combine == .all || !anyTested
    }

    /// nil = the rule is skipped (inactive, or its index answer has not arrived).
    private static func test(_ rule: NotesSearchRule, _ item: ItemSummary, _ context: NotesRuleContext) -> Bool? {
        guard rule.isActive else { return nil }
        let positive = rule.op != .isNot
        switch rule.field {
        case .text, .noteText:
            guard let hits = context.textHits[rule.id] else { return nil }
            return rule.op == .noWords ? !hits.contains(item.id) : hits.contains(item.id)
        case .title:
            let q = rule.text.trimmingCharacters(in: .whitespaces)
            let opts: String.CompareOptions = [.caseInsensitive]   // as the filter bar's title predicate
            switch rule.op {
            case .doesNotContain: return item.title.range(of: q, options: opts) == nil
            case .beginsWith: return item.title.range(of: q, options: opts.union(.anchored)) != nil
            case .endsWith: return item.title.range(of: q, options: opts.union([.anchored, .backwards])) != nil
            default: return item.title.range(of: q, options: opts) != nil
            }
        case .authors:
            let q = rule.text.trimmingCharacters(in: .whitespaces)
            let found = item.authors.contains { $0.range(of: q, options: .caseInsensitive) != nil }
            return rule.op == .doesNotContain ? !found : found
        case .tags:
            let have = Set(item.managedTags.map { $0.lowercased() })
            let wanted = rule.tagList.map { $0.lowercased() }
            switch rule.op {
            case .hasAny: return wanted.contains(where: have.contains)
            case .hasNone: return !wanted.contains(where: have.contains)
            default: return wanted.allSatisfy(have.contains)
            }
        case .kind: return (item.kind == rule.kind) == positive
        case .quality: return rule.qualities.contains(item.quality ?? 0) == positive
        case .date:
            return AdvancedSearchText.dateMatches(op: rule.op, bounds: rule.dateBounds, role: rule.dateRole,
                                                  keys: item.dateKeysByRole)
        case .uncertainDate:
            return (item.dateUncertain || item.sentWithUncertain) == positive
        case .folder:
            guard let id = rule.folderId else { return nil }
            return (context.folderItems[id]?.contains(item.id) ?? false) == positive
        case .roundup: return item.roundup == positive
        case .group: return evaluate(rule.children, rule.combine, item, context)
        }
    }
}

// MARK: - From the filter bar

extension NotesAdvancedSearch {
    /// The rules that say what a filter-bar state and search box say, for saving it as a smart folder or opening
    /// it in the form. The search box's own rule is kept: it searches every column and its last word matches as
    /// a prefix when longer than two characters (`NotesIndex.ftsMatchExpression`). `includingKind: false` leaves
    /// the window's kind control out, for the form, which keeps that control on the window.
    init(filter f: NotesFilter, keyword: String, includingKind: Bool = true) {
        var rules: [NotesSearchRule] = []
        // As the live query: a `*` typed inside the box is no prefix except on the last word.
        var ws = keyword.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !AdvancedSearchText.words(keyword).isEmpty {
            var r = NotesSearchRule(field: .text, op: .allWords)
            for i in ws.indices.dropLast() where ws[i].hasSuffix("*") { ws[i] = String(ws[i].dropLast()) }
            if let last = ws.last, last.count > 2, !last.hasSuffix("*") { ws[ws.count - 1] = last + "*" }
            r.text = ws.joined(separator: " ")
            rules.append(r)
        }
        if let id = f.folderId { rules.append(.folder(id)) }
        if includingKind, f.kind != .all {
            var r = NotesSearchRule(field: .kind); r.kind = f.kind == .notes ? .note : .extract
            rules.append(r)
        }
        if !f.tags.isEmpty {
            var r = NotesSearchRule(field: .tags, op: f.tagCombine == .any ? .hasAny : .hasAll)
            r.text = f.tags.joined(separator: ", ")
            rules.append(r)
        }
        if !f.qualities.isEmpty {
            var r = NotesSearchRule(field: .quality); r.qualities = f.qualities; rules.append(r)
        }
        if f.dateFrom != nil || f.dateTo != nil {
            var r = NotesSearchRule(field: .date, op: .between)
            r.text = f.dateFrom.map { Self.keyText($0, upper: false) } ?? ""
            r.text2 = f.dateTo.map { Self.keyText($0, upper: true) } ?? ""
            rules.append(r)
        }
        if let roundup = f.roundup { rules.append(NotesSearchRule(field: .roundup, op: roundup ? .is : .isNot)) }
        let title = f.searchText.trimmingCharacters(in: .whitespaces)
        if !title.isEmpty {
            var r = NotesSearchRule(field: .title); r.text = title; rules.append(r)
        }
        self.init(combine: .all, rules: rules)
    }

    /// A filter-bar date bound as the text a date rule reads. The bar sets whole years (`year*10000` and
    /// `year*10000 + 1231`), which read back as the year; any other key is written as its full date.
    private static func keyText(_ key: Int, upper: Bool) -> String {
        let y = key / 10_000, md = key % 10_000
        if md == (upper ? 1231 : 0) { return String(y) }
        let m = max(md / 100, 1), d = max(md % 100, 1)
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    /// `self` narrowed by `more`: both must match. Flat when `self` is "all", else `self` becomes a group.
    func narrowed(by more: NotesAdvancedSearch) -> NotesAdvancedSearch {
        guard more.isActive else { return self }
        guard isActive else { return more }
        let mine = combine == .all ? rules : [NotesSearchRule.group(combine, rules)]
        let theirs = more.combine == .all ? more.rules : [NotesSearchRule.group(more.combine, more.rules)]
        return NotesAdvancedSearch(combine: .all, rules: mine + theirs)
    }
}
