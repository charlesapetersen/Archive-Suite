import Foundation
import ArchiveCore

/// What produced the collections a note's linked PDFs sit in (W46.settings-reader-notes): the Processor's settings
/// document beside each collection (`SPEC/collection-settings.md`), read only under Reader roots already granted.
/// Like `RoundupYearSuggestion`, it never prompts, never walks a corpus, and never writes; a link that does not
/// resolve is skipped.
enum CollectionRecordLookup {
    /// At most this many collections are shown for one note.
    static let maxCollections = 4

    static func records(links: [String], roots: [UUID: URL]) async -> [CollectionSettingsRecord] {
        let task = Task.detached(priority: .utility) { read(links: links, roots: roots) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    static func read(links: [String], roots: [UUID: URL]) -> [CollectionSettingsRecord] {
        var records: [CollectionSettingsRecord] = []
        var seenFolders: Set<URL> = []
        var seenFiles: Set<URL> = []
        for link in links {
            guard !Task.isCancelled, records.count < maxCollections else { break }
            guard let url = URL(string: link),
                  case .readerReveal(let guid, let relativePath, _, _) = DurableLink(url: url),
                  let root = roots[guid] else { continue }
            // Own a short lease without releasing the preview popover's root scope.
            let started = root.startAccessingSecurityScopedResource()
            defer { if started { root.stopAccessingSecurityScopedResource() } }
            guard let marker = try? RootMarker.read(at: root), marker.guid == guid, marker.kind == .reader else {
                continue
            }
            let canonicalRoot = ReaderRootContainment.canonical(root)
            let file = ReaderRootContainment.canonical(root.appendingPathComponent(relativePath))
            guard ReaderRootContainment.isContained(file, inCanonicalRoot: canonicalRoot),
                  seenFiles.insert(file).inserted,
                  let folder = CollectionSettingsRecord.locate(from: file, within: canonicalRoot),
                  seenFolders.insert(folder).inserted,
                  let record = CollectionSettingsRecord.load(collectionFolder: folder) else { continue }
            records.append(record)
        }
        return Task.isCancelled ? [] : records
    }
}
