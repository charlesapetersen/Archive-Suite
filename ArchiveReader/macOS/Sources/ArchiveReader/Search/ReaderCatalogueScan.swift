import ArchiveCore
import Foundation

/// Inventories the complete granted root once, independently of Finder metadata.
struct ReaderCatalogueScan: Sendable {
    let reader: CatalogueReader?
    let snapshot: CatalogueReader.Snapshot?
    let rows: [ArchiveFile]
    let health: CorpusScanResult
    let rootStability: RootStability

    static func run(root: URL, instance: UUID, isCancelled: @Sendable () -> Bool,
                    onProgress: @escaping @Sendable (Int) -> Void) -> Self {
        CorpusWalker.withDatalessMaterializationDisabled {
            let before = CorpusRootFingerprint.capture(root)
            let reader = try? CatalogueReader(grantedRoot: root, rootInstanceID: instance,
                                              mode: .adopted, identifyPDF: CataloguePDFIdentity.identify)
            let scan = CorpusWalker.scanFingerprints(root: root, options: .init(enumerationOptions: []),
                                                     followFileSymlinks: false, isCancelled: isCancelled,
                                                     onProgress: onProgress)
            let candidates = scan.entries.compactMap { entry -> (CorpusFingerprintEntry, String)? in
                guard let rootPath = scan.rootPath, entry.url.pathExtension.lowercased() == "pdf",
                      let path = relativePath(of: entry.url, under: rootPath) else { return nil }
                return (entry, path)
            }
            let snapshot = isCancelled() ? nil : reader?.snapshot(
                .init(relativePDFPaths: candidates.map(\.1), isComplete: scan.isClean && scan.vanishedMidScan == 0)
            )
            let after = CorpusRootFingerprint.capture(root)
            let stability = RootStability.between(before, after)
            let scopedSnapshot = stability == .heldStill ? snapshot : nil
            let rows = candidates.map { entry, path in
                let facts = scopedSnapshot?.facts(at: path)
                let record = (try? facts?.file.get())?.pair.record
                let pageByDocument = record?.pages.reduce(into: [UUID: Int]()) {
                    $0[$1.documentID] = min($0[$1.documentID] ?? $1.physicalIndex, $1.physicalIndex)
                } ?? [:]
                let selections = (record?.documents ?? []).compactMap { document in
                    pageByDocument[document.id].flatMap { scopedSnapshot?.facts(at: path, physicalPageIndex: $0) }
                }
                return ArchiveFile(url: entry.url, name: entry.url.lastPathComponent, fileType: "PDF",
                                   tags: ReaderCatalogueFacets.tags(file: facts, document: facts),
                                   contentModified: Date(timeIntervalSince1970: entry.fingerprint.mtime),
                                   contentIdentity: ContentIdentity(entry.fingerprint),
                                   isDataless: entry.fingerprint.isDataless,
                                   provenance: .disk(readAt: Date()), isCatalogue: true, catalogueFacts: facts,
                                   catalogueDocuments: selections)
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let health = CorpusScanResult(entries: [], unreadable: scan.unreadable,
                                          directoryErrors: scan.directoryErrors, filesSeen: scan.filesSeen,
                                          vanishedMidScan: scan.vanishedMidScan,
                                          rootUnreadable: scan.rootUnreadable || reader == nil,
                                          cancelled: scan.cancelled)
            return Self(reader: scopedSnapshot == nil ? nil : reader, snapshot: scopedSnapshot,
                        rows: rows, health: health, rootStability: stability)
        }
    }

    static func relativePath(of url: URL, under rootPath: String) -> String? {
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return url.withUnsafeFileSystemRepresentation { representation in
            guard let representation, let path = String(validatingCString: representation),
                  path.utf8.starts(with: prefix.utf8) else { return nil }
            return String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        }
    }
}
