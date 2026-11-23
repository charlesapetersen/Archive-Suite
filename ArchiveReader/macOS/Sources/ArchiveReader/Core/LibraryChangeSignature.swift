import Foundation

/// Cheap, order-independent change-signatures over the library snapshot. `NavigationModel` uses these
/// to skip rebuilding path-/subject-invariant derived state on every `library.files` emission (and to
/// avoid re-running it on a repeat emission — a re-walk or an FSEvents re-inspection that republishes an
/// identically-valued snapshot; written for the Spotlight index echo, the mechanism carried over unchanged
/// when `W26.walk2` removed Spotlight): if a signature is unchanged, the corresponding
/// cache is left as-is. A false "unchanged" only ever yields a briefly-stale *derived* cache (never a
/// data risk), self-healing on the next real change.
///
/// Pure and UI-free (no `@MainActor`, no SwiftUI) so it is directly unit-testable and package-ready.
enum LibraryChangeSignature {

    /// Signature of the **distinct subject union** — exactly what `refreshSubjectsCache` derives.
    ///
    /// This MUST be over the deduplicated union, NOT the flat per-file multiset. XOR is self-inverse
    /// (`a ^ a == 0`), so an XOR over the raw multiset drops any subject carried by an *even* number of
    /// files. An even-count rename or group-edit (≈ half of all edits) would then XOR to the same value
    /// and wrongly report "unchanged", leaving the ⌘L autocomplete + near-duplicate check stale. A set
    /// has no duplicates: a first occurrence XORs its hash in and a last removal XORs it out, so the
    /// signature changes exactly when the union does. (A distinct-set hash collision — ≈ 1/2^64 — is the
    /// only remaining false-negative, self-healing on the next change: the rare case the guard tolerates.)
    static func subjects(_ files: [ArchiveFile]) -> Int {
        Set(files.flatMap(\.subjects)).reduce(0) { $0 ^ $1.hashValue }
    }

    /// Signature of the set of file paths (drives the folder tree). One entry per unique path, so no
    /// structural cancellation is possible.
    static func paths(_ files: [ArchiveFile]) -> Int {
        files.reduce(0) { $0 ^ $1.pathHash }
    }

    /// Signature of every facet that affects smart-folder matching (path + read-state + quality +
    /// subjects), as a per-file composite hash. Folding the unique `url.path` into each file's hash
    /// means distinct files never structurally cancel, so parity is a non-issue here.
    static func matchFacets(_ files: [ArchiveFile]) -> Int {
        files.reduce(0) { $0 ^ matchFacets(of: $1) }
    }

    /// One file's part of `matchFacets`: a changed row moves the signature by `old ^ new`.
    static func matchFacets(of f: ArchiveFile) -> Int {
        var h = Hasher()
        h.combine(f.pathHash)
        h.combine(f.readState)
        h.combine(f.quality)
        if f.isCatalogue {
            h.combine(f.catalogueFlag)
            h.combine(f.catalogueFileFields?.readState?.fieldRevision)
            for document in f.catalogueDocuments {
                h.combine((try? document.document.get())?.owner.revision)
            }
        }
        for s in f.subjects { h.combine(s) }
        return h.finalize()
    }

    /// Signature of the container facet values smart-folder rules match (W47.ct-reader-facet-rules): each listed
    /// file's path with its folded facet values. Like `matchFacets`, the path in each part keeps files apart.
    static func containers(_ rows: [String: ContainerRow]) -> Int {
        rows.reduce(0) { sig, entry in
            var h = Hasher()
            h.combine(entry.key)
            for facet in ContainerFacet.allCases { h.combine(entry.value.facetKeys[facet]) }
            return sig ^ h.finalize()
        }
    }
}
