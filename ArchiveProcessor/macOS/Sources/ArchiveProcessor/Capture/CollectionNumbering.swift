import Foundation

/// Shared collection-folder numbering used by the two append paths that renumber output into an existing
/// collection folder: `CollectionSegmenter.organizeOutput` (Process Files) and
/// `LiveCaptureProcessor.executePlans` (Live Capture). Kept in ONE place so the two paths can never drift
/// (they were previously duplicated as `highestNumberPrefix` / `maxExistingNumber`, both byte-identical).
enum CollectionNumbering {
    /// New names carry six digits (`000001 Collection.pdf`; owner, 2026-11-20, call 26). Folders filed
    /// before then hold five-digit names; those are never renamed, and numbering continues past them.
    nonisolated static let width = 6

    /// The zero-padded sequence number a new filed name starts with.
    nonisolated static func format(_ number: Int) -> String {
        String(format: "%0\(width)d", number)
    }

    /// Highest leading number among files directly in `folder` (0 if none) — so re-running or appending a
    /// collection into an existing output folder continues numbering instead of restarting at 000001
    /// (which would collide with / overwrite an already-filed file). A name counts when it starts with a
    /// run of five or six digits (the old and new widths), so a folder of `00041 …` files goes on at
    /// `000042`.
    nonisolated static func highestLeadingNumber(in folder: URL, fm: FileManager = .default) -> Int {
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var maxN = 0
        for u in items {
            if let n = leadingNumber(of: u.lastPathComponent) { maxN = max(maxN, n) }
        }
        return maxN
    }

    /// The leading five- or six-digit number of a filed name, or nil when the name starts with fewer or
    /// more digits than that.
    nonisolated static func leadingNumber(of name: String) -> Int? {
        let digits = name.prefix(while: { $0.isASCII && $0.isNumber })
        guard digits.count == 5 || digits.count == width else { return nil }
        return Int(digits)
    }
}
