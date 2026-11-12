import Foundation
import ArchiveCore

/// Describes only what the writer verified, never the inverse it was asked to apply. A concurrent
/// edit can turn part (or all) of that inverse into a no-op. Presentation only; no tag reads or writes.
enum TagChangeStatus {
    static func reversal(_ results: [TagWriteResult], redo: Bool) -> String {
        let changed = results.filter { !$0.isNoOp }
        let prefix = "\(redo ? "Redid" : "Undid") \(changed.count) change\(changed.count == 1 ? "" : "s")"
        guard !changed.isEmpty else { return prefix }

        // A group can reverse several successive writes to one file. Coalesce only continuous
        // snapshots: a gap is another process's edit, which this action must never claim to have made.
        let files = Dictionary(grouping: changed, by: { $0.url.path })
        var descriptions: [String: Int] = [:]
        for writes in files.values {
            guard let first = writes.first, let last = writes.last else { continue }
            let continuous = zip(writes, writes.dropFirst()).allSatisfy { previous, next in
                previous.after.sorted() == next.before.sorted()
                    && (previous.afterLabel ?? 0) == (next.beforeLabel ?? 0)
            }
            let detail: String
            if continuous {
                detail = describe(before: first.before, after: last.after,
                                  beforeLabel: first.beforeLabel, afterLabel: last.afterLabel)
            } else {
                detail = writes.map { describe(before: $0.before, after: $0.after,
                                               beforeLabel: $0.beforeLabel, afterLabel: $0.afterLabel) }
                    .joined(separator: "; then ")
            }
            descriptions[detail, default: 0] += 1
        }
        let target: String
        if files.count == 1, let path = files.keys.first {
            target = URL(fileURLWithPath: path).lastPathComponent
        } else { target = "\(files.count) files" }
        let details = descriptions.sorted { $0.key < $1.key }.map { detail, count in
            files.count == 1 ? detail : "\(detail) (\(count) file\(count == 1 ? "" : "s"))"
        }.joined(separator: "; ")
        return "\(prefix) in \(target): \(details)"
    }

    private static func describe(before: [String], after: [String], beforeLabel: Int?, afterLabel: Int?) -> String {
        let markerTokens = Set([beforeLabel, afterLabel].compactMap { label in
            FinderLabel(labelNumber: label)?.tokenName
        })
        func fields(_ tags: [String]) -> [Field: [String]] {
            Dictionary(grouping: tags) { token in
                let parsed = DocumentTags.parse(raw: [token], labelNumber: nil)
                if parsed.readState != nil { return .readState }
                if parsed.yearToken != nil { return .year }
                if parsed.monthToken != nil { return .month }
                if parsed.dayToken != nil { return .day }
                if parsed.decadeToken != nil { return .decade }
                if parsed.dateUncertain { return .dateUncertain }
                if parsed.sentWithToken != nil { return .sentWith }
                if parsed.sentWithUncertain { return .sentWithUncertain }
                if parsed.qualityToken != nil { return .quality }
                if parsed.itemTypeToken != nil { return .itemType }
                if markerTokens.contains(where: { isSameTag($0, token) }) { return .colorTags }
                return .subjects
            }
        }
        let old = fields(before), new = fields(after)
        var details: [String] = []
        for field in Field.allCases {
            let a = (old[field] ?? []).sorted(), b = (new[field] ?? []).sorted()
            guard a != b else { continue }
            if field == .subjects {
                // Show the precise multiset delta without implying that unrelated subjects vanished.
                let removed = subtract(a, b), added = subtract(b, a)
                var edits: [String] = []
                if !removed.isEmpty { edits.append("removed \(values(removed))") }
                if !added.isEmpty { edits.append("added \(values(added))") }
                details.append("Subjects: " + edits.joined(separator: ", "))
            } else { details.append("\(field.rawValue): \(values(a)) → \(values(b))") }
        }
        if (beforeLabel ?? 0) != (afterLabel ?? 0) {
            details.append("Color: \(color(beforeLabel)) → \(color(afterLabel))")
        }
        return details.isEmpty ? "no net tag change" : details.joined(separator: "; ")
    }

    private enum Field: String, CaseIterable {
        case readState = "Read state", year = "Year", month = "Month", day = "Day", decade = "Decade"
        case dateUncertain = "Date uncertain", sentWith = "Sent with", sentWithUncertain = "Sent with uncertain"
        case quality = "Quality", itemType = "Item type", colorTags = "Color tags", subjects = "Subjects"
    }

    private static func values(_ tokens: [String]) -> String {
        tokens.isEmpty ? "none" : tokens.map { "“\($0)”" }.joined(separator: ", ")
    }

    private static func subtract(_ lhs: [String], _ rhs: [String]) -> [String] {
        var remaining = rhs.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return lhs.filter { token in
            if remaining[token, default: 0] > 0 { remaining[token, default: 0] -= 1; return false }
            return true
        }
    }

    private static func color(_ label: Int?) -> String {
        guard let label, label != 0 else { return "none" }
        return FinderLabel(labelNumber: label)?.tokenName ?? "Finder label \(label)"
    }
}
