import Foundation
import ArchiveCore

/// Read-only year suggestion from exact PDF links under already-granted Reader roots. A missing,
/// undated, renamed, or inaccessible source suppresses the offer; this never prompts or walks a corpus.
/// The year is the linked document's own date in the PDF's catalogue record, the same read Copy for Zotero
/// makes (`CatalogueSourceFacts`, W49.storage-notes-zotero); only a file with no catalogue identity uses its tags.
enum RoundupYearSuggestion {
    static func commonYear(links: [String], roots: [UUID: URL]) async -> Int? {
        let task = Task.detached(priority: .utility) { readYear(links: links, roots: roots) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    static func readYear(links: [String], roots: [UUID: URL],
                         identifyPDF: @escaping CatalogueReader.IdentifyPDF = CataloguePDFIdentity.identify) -> Int? {
        guard !links.isEmpty else { return nil }
        var year: Int?
        var visited: Set<String> = []
        for link in links {
            guard !Task.isCancelled,
                  let url = URL(string: link),
                  case .readerReveal(let guid, let relativePath, let page, _) = DurableLink(url: url),
                  relativePath.lowercased().hasSuffix(".pdf"),
                  let root = roots[guid] else { return nil }
            // Own a short lease without releasing the preview popover's root scope.
            let started = root.startAccessingSecurityScopedResource()
            let sourceYear: Int? = {
                defer { if started { root.stopAccessingSecurityScopedResource() } }
                guard let marker = try? RootMarker.read(at: root), marker.guid == guid,
                      marker.kind == .reader else { return nil }
                let file = ReaderRootContainment.canonical(root.appendingPathComponent(relativePath))
                guard ReaderRootContainment.isContained(file, inCanonicalRoot: ReaderRootContainment.canonical(root))
                else { return nil }
                // Different pages of one file can be different documents with different dates.
                let key = "\(file.path)#\(page.map(String.init) ?? "")"
                if visited.contains(key) { return year }
                visited.insert(key)
                // No owner walk: a split document whose owner is another file suppresses the offer.
                let resolution = CatalogueSourceFacts.resolve([.init(relativePath: relativePath, page: page)],
                                                              grantedRoot: root, inventoryForForeignOwners: false,
                                                              identifyPDF: identifyPDF)[0]
                if case .unadopted = resolution { return TagReading.readTags(file)?.year }
                return CatalogueSourceFacts.year(resolution)
            }()
            guard let sourceYear, sourceYear > 0 else { return nil }
            if let year, year != sourceYear { return nil }
            year = sourceYear
        }
        return Task.isCancelled ? nil : year
    }
}
