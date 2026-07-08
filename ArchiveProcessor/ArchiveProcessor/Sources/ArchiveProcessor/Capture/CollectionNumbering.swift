import Foundation

/// Shared collection-folder numbering used by the two append paths that renumber output into an existing
/// collection folder: `CollectionSegmenter.organizeOutput` (Process Files) and
/// `LiveCaptureProcessor.executePlans` (Live Capture). Kept in ONE place so the two paths can never drift
/// (they were previously duplicated as `highestNumberPrefix` / `maxExistingNumber`, both byte-identical).
enum CollectionNumbering {
    /// Highest leading NNNNN number among files directly in `folder` (0 if none) — so re-running or
    /// appending a collection into an existing output folder continues numbering instead of restarting
    /// at 00001 (which would collide with / overwrite an already-filed file).
    nonisolated static func highestLeadingNumber(in folder: URL, fm: FileManager = .default) -> Int {
        guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var maxN = 0
        for u in items {
            let prefix = u.lastPathComponent.prefix(5)
            if prefix.count == 5, prefix.allSatisfy(\.isNumber), let n = Int(prefix) { maxN = max(maxN, n) }
        }
        return maxN
    }
}
