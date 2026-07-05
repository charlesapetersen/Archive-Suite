import Foundation

/// Recovers a "document run" — a `Document Start` plus its following `Continuation` pages — from a
/// list of classifications in filename-sequence order. Pure & UI-free; used by the opt-in
/// "select document run" convenience. Degrades safely: if the classification at `index` is unknown
/// or not a start, the run is just that single item.
enum DocumentRuns {
    static func run(startingAt index: Int, classifications: [String?]) -> ClosedRange<Int>? {
        guard classifications.indices.contains(index) else { return nil }
        var end = index
        var i = index + 1
        while i < classifications.count, isContinuation(classifications[i]) {
            end = i
            i += 1
        }
        return index...end
    }

    /// The run CONTAINING `index`: walk back to the nearest Start (or list start / a marker boundary),
    /// then forward across Continuations. Handles selecting a run from any page within it.
    static func runContaining(_ index: Int, classifications: [String?]) -> ClosedRange<Int>? {
        guard classifications.indices.contains(index) else { return nil }
        var start = index
        // Walk back while the current page is a Continuation and the previous isn't a boundary.
        while start > 0, isContinuation(classifications[start]) {
            start -= 1
            if isStart(classifications[start]) || isMarker(classifications[start]) { break }
        }
        return run(startingAt: start, classifications: classifications)
    }

    static func isStart(_ c: String?) -> Bool { norm(c) == "document start" }
    static func isContinuation(_ c: String?) -> Bool { norm(c) == "continuation" }
    static func isMarker(_ c: String?) -> Bool { let n = norm(c); return n == "box" || n == "folder" }

    private static func norm(_ c: String?) -> String {
        (c ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }
}
