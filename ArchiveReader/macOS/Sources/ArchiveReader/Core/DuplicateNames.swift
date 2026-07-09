import Foundation

/// Detects when displayed rows share a base filename — common at corpus scale (e.g. `00001 IMG —
/// Brown.pdf` recurring across boxes/folders) — so the nav list can surface each colliding row's
/// containing folder to tell otherwise-identical rows apart. A DISPLAY aid only: never mutates a
/// file and never drives a write. Pure & UI-free (package-ready like `DocumentTags`/`DocumentRuns`).
enum DuplicateNames {
    /// The base filenames occurring on ≥2 files, returned **lowercased** (case-insensitive collision:
    /// `Report.pdf` and `report.pdf` count as duplicates). Test a single name via `isDuplicated(_:in:)`.
    static func duplicatedNames(in files: [ArchiveFile]) -> Set<String> {
        var counts: [String: Int] = [:]
        for f in files { counts[f.name.lowercased(), default: 0] += 1 }
        return Set(counts.compactMap { $0.value >= 2 ? $0.key : nil })
    }

    /// Whether `name` collides (case-insensitively) with another displayed row's name — i.e. its
    /// lowercased form is in `duplicated` (the set from `duplicatedNames(in:)`).
    static func isDuplicated(_ name: String, in duplicated: Set<String>) -> Bool {
        duplicated.contains(name.lowercased())
    }

    /// The disambiguating containing-folder name for a file — its parent directory's last component.
    static func disambiguator(for url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }
}
