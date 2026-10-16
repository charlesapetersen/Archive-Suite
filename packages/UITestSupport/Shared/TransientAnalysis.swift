// TransientAnalysis.swift — the pure half of the transient-state recorder (W40.e13). ONE file, compiled into each
// macOS app (beside `../App/TransientRecorder.swift`, which feeds it what the app showed) and into each UI-test
// bundle (beside `../Runner/TransientCheck.swift`, whose self-test feeds it synthetic sequences), through each
// app's `project.yml`. DEBUG only on both sides.
//
// THE RULE. A transition (select the next note, switch folder, open a sheet) takes a watched section of the screen
// from one settled state to another. Every state it shows on the way must be the old one, the new one, or — for
// geometry only — a step of a smooth move between them. It fails when a section shows anything else:
//
//   • value     — a text that is neither the old nor the new (the inspector drawn once empty, or half updated);
//   • reverted  — the new text shown, then the old one again;
//   • removed   — the section left the screen and came back;
//   • geometry  — a frame outside the old→new range, or one that changes direction (a height that grows and
//                 shrinks back);
//   • structure — elements added or removed and then put back (neither the old nor the new element list).
//
// One finding per section per kind per transition: the first offending step, which is the reproduction.

#if DEBUG
import Foundation

/// One accessibility element of a watched section as the app showed it: frame in whole points, relative to its
/// window, so a move of the whole window is not a change.
struct TransientEntry: Equatable, Sendable {
    var role: String
    var identifier: String
    var text: String
    var x: Int, y: Int, w: Int, h: Int

    var name: String { identifier.isEmpty ? role : identifier }
    var coordinates: [Int] { [x, y, w, h] }
}

/// A watched section's whole state at one sample. No entries means the section was not on the screen.
struct TransientSectionState: Equatable, Sendable {
    var entries: [TransientEntry] = []
    var texts: [String] { entries.map(\.text) }
    var shape: [String] { entries.map(\.name) }
}

struct TransientFinding: Equatable, Sendable, CustomStringConvertible {
    enum Kind: String, Sendable { case value, reverted, removed, geometry, structure }
    var section: String
    var kind: Kind
    var detail: String
    var description: String { "\(section) \(kind.rawValue): \(detail)" }
}

enum TransientAnalysis {
    /// `states` are the DISTINCT consecutive states one section passed through in one transition: the first is
    /// the settled state before it, the last the settled state after. Two or fewer states cannot hold a transient.
    static func findings(section: String, states: [TransientSectionState]) -> [TransientFinding] {
        guard states.count > 2, let old = states.first, let new = states.last else { return [] }
        var found: [TransientFinding.Kind: TransientFinding] = [:]
        func note(_ kind: TransientFinding.Kind, _ detail: String) {
            if found[kind] == nil { found[kind] = TransientFinding(section: section, kind: kind, detail: detail) }
        }
        let last = states.count - 1
        var reachedNew = false
        for i in 1..<last {
            let s = states[i]
            let step = "step \(i) of \(last)"
            if s.entries.isEmpty, !old.entries.isEmpty, !new.entries.isEmpty {
                note(.removed, "\(step): the section left the screen and came back")
                continue
            }
            if s.texts != old.texts, s.texts != new.texts {
                note(.value, "\(step): \(textDifference(s, old: old, new: new))")
            } else if s.texts == new.texts, old.texts != new.texts {
                reachedNew = true
            } else if reachedNew, s.texts == old.texts {
                note(.reverted, "\(step): the new text was shown, then the old one again")
            }
            if s.shape != old.shape, s.shape != new.shape {
                note(.structure, "\(step): \(s.entries.count) elements, \(old.entries.count) before and "
                     + "\(new.entries.count) after")
            }
        }
        // Geometry only where every state has the same elements, so element j is the same element throughout.
        let shape = old.shape
        if states.allSatisfy({ $0.shape == shape }) {
            outer: for j in old.entries.indices {
                for c in 0..<4 {
                    let values = states.map { $0.entries[j].coordinates[c] }
                    if let problem = geometryProblem(values) {
                        note(.geometry, "\(old.entries[j].name) \(["x", "y", "width", "height"][c]) "
                             + "\(values.map(String.init).joined(separator: "→")): \(problem)")
                        break outer
                    }
                }
            }
        }
        let order: [TransientFinding.Kind] = [.removed, .value, .reverted, .structure, .geometry]
        return order.compactMap { found[$0] }
    }

    /// nil when `values` goes from its first to its last without leaving that range and without turning back.
    static func geometryProblem(_ values: [Int]) -> String? {
        guard let a = values.first, let b = values.last else { return nil }
        let lo = min(a, b), hi = max(a, b)
        if let out = values.first(where: { $0 < lo || $0 > hi }) { return "\(out) is outside \(a)…\(b)" }
        var direction = 0
        for (p, q) in zip(values, values.dropFirst()) where p != q {
            let d = q > p ? 1 : -1
            if direction != 0, d != direction { return "changes direction" }
            direction = d
        }
        return nil
    }

    private static func textDifference(_ s: TransientSectionState, old: TransientSectionState,
                                       new: TransientSectionState) -> String {
        if s.entries.count == old.entries.count, s.entries.count == new.entries.count {
            for j in s.entries.indices where s.entries[j].text != old.entries[j].text
                && s.entries[j].text != new.entries[j].text {
                return "\(s.entries[j].name) showed \(quote(s.entries[j].text)) between "
                    + "\(quote(old.entries[j].text)) and \(quote(new.entries[j].text))"
            }
            return "a mix of the old and the new texts"
        }
        let extra = s.texts.first { !old.texts.contains($0) && !new.texts.contains($0) }
        return "\(s.entries.count) elements (\(old.entries.count) before, \(new.entries.count) after)"
            + (extra.map { ", showing \(quote($0))" } ?? "")
    }

    static func quote(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: "⏎")
        return "\"" + (flat.count > 40 ? flat.prefix(40) + "…" : flat) + "\""
    }
}
#endif
