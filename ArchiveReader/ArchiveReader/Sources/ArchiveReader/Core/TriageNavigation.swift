import Foundation

/// Pure, UI-free selection math for the keyboard triage flow (G4): find the next / previous row that
/// still carries `Unread`, skipping already-read rows, with optional wrap-around. It performs NO tag
/// mutation and touches no file — it only computes an index; the caller moves the selection and routes
/// any read-state change through the audited `TagWriter`. Kept in `Core/` (like `DocumentRuns`) so it
/// is unit-testable without a window and can move into the shared `ArchiveCore` package later.
enum TriageNavigation {

    /// Index of the next row satisfying `isUnread`, scanning forward from just *after* `anchor`
    /// (or from row 0 when `anchor` is nil), optionally wrapping around to the top.
    /// - Returns `nil` when no row satisfies `isUnread`.
    /// - When `anchor`'s own row is the *only* match, wrapping lands back on it and it is returned; the
    ///   caller can detect "no other unread" by comparing the result to the current anchor.
    static func nextUnread(after anchor: Int?, count: Int, wrap: Bool = true,
                           isUnread: (Int) -> Bool) -> Int? {
        guard count > 0 else { return nil }
        let start = (anchor ?? -1) + 1
        if start < count {
            for i in start..<count where isUnread(i) { return i }
        }
        guard wrap else { return nil }
        let wrapEnd = min(max(start, 0), count)          // scan [0, start)
        if wrapEnd > 0 {
            for i in 0..<wrapEnd where isUnread(i) { return i }
        }
        return nil
    }

    /// Index of the previous row satisfying `isUnread`, scanning backward from just *before* `anchor`
    /// (or from the last row when `anchor` is nil), optionally wrapping around to the bottom. Mirror of
    /// `nextUnread`; returns `nil` when nothing matches.
    static func previousUnread(before anchor: Int?, count: Int, wrap: Bool = true,
                               isUnread: (Int) -> Bool) -> Int? {
        guard count > 0 else { return nil }
        let start = (anchor ?? count) - 1
        if start >= 0 {
            var i = start
            while i >= 0 { if isUnread(i) { return i }; i -= 1 }
        }
        guard wrap else { return nil }
        var i = count - 1                                 // scan (start, count) top-down
        while i > start { if isUnread(i) { return i }; i -= 1 }
        return nil
    }
}
