import Foundation
import ArchiveCore

/// Read-only year suggestion from exact PDF links under already-granted Reader roots. A missing,
/// undated, renamed, or inaccessible source suppresses the offer; this never prompts or walks a corpus.
enum RoundupYearSuggestion {
    static func commonYear(links: [String], roots: [UUID: URL]) async -> Int? {
        let task = Task.detached(priority: .utility) { readYear(links: links, roots: roots) }
        return await withTaskCancellationHandler(operation: { await task.value }, onCancel: { task.cancel() })
    }

    private static func readYear(links: [String], roots: [UUID: URL]) -> Int? {
        guard !links.isEmpty else { return nil }
        var year: Int?
        var visited: Set<URL> = []
        for link in links {
            guard !Task.isCancelled,
                  let url = URL(string: link),
                  case .readerReveal(let guid, let relativePath, _, _) = DurableLink(url: url),
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
                if visited.contains(file) { return year }
                visited.insert(file)
                return TagReading.readTags(file)?.year
            }()
            guard let sourceYear, sourceYear > 0 else { return nil }
            if let year, year != sourceYear { return nil }
            year = sourceYear
        }
        return Task.isCancelled ? nil : year
    }
}
