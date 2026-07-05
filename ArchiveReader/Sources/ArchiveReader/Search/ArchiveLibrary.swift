import Foundation
import Combine

/// Discovers the tagged-PDF universe via Spotlight (`NSMetadataQuery`) and keeps it live-updated.
///
/// The master predicate is "has a Read or Unread tag" — the set of files Archive Reader cares about.
/// Each result carries its tags/name/type/dates from the Spotlight index, so building the list needs
/// no per-file disk I/O (the fast path at 150k). Tag facets here are for display/sort/filter only;
/// the authoritative read for a write is done inside `TagWriter`.
@MainActor
final class ArchiveLibrary: ObservableObject {
    @Published private(set) var files: [ArchiveFile] = []
    @Published private(set) var isGathering = false
    @Published private(set) var scopeDescription = "No folder selected"

    private let query = NSMetadataQuery()

    init() {
        query.predicate = NSPredicate(format: "(kMDItemUserTags == %@) || (kMDItemUserTags == %@)",
                                      ReadState.read.rawValue, ReadState.unread.rawValue)
        query.valueListAttributes = [
            NSMetadataItemPathKey, NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey,
            NSMetadataItemFSContentChangeDateKey, "kMDItemUserTags", "kMDItemFSLabel",
        ]
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        nc.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Start (or restart) discovery within a scope. `nil` scope searches the whole Mac (future use);
    /// v1 passes the user-granted archive root.
    func start(scope: URL?) {
        query.stop()
        if let scope {
            query.searchScopes = [scope]
            scopeDescription = scope.lastPathComponent
        } else {
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
            scopeDescription = "This Mac"
        }
        files = []           // clear prior results so the "processing" spinner shows during (re)gather
        isGathering = true
        query.start()
    }

    /// Optimistically reflect a Read/Unread change in the model so a row leaves a filtered view
    /// immediately; the Spotlight query catches up shortly after (eventual consistency).
    func applyOptimisticReadState(_ target: ReadState, for urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        files = files.map { f in
            guard urls.contains(f.url) else { return f }
            var raw = f.tags.raw.filter { $0.caseInsensitiveCompare(ReadState.read.rawValue) != .orderedSame
                                       && $0.caseInsensitiveCompare(ReadState.unread.rawValue) != .orderedSame }
            // Only stamp a read-state if the file already had one (mirror TagWriter's marker guard).
            if f.readState != nil { raw.append(target.rawValue) }
            return ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                               tags: DocumentTags.parse(raw: raw, labelNumber: f.tags.labelNumber),
                               contentModified: f.contentModified)
        }
    }

    /// Set a file's tags exactly in the model (used for precise optimistic undo). Does not write disk.
    func setExactTags(_ raw: [String], label: Int?, for url: URL) {
        files = files.map { f in
            f.url == url
                ? ArchiveFile(url: f.url, name: f.name, fileType: f.fileType,
                              tags: DocumentTags.parse(raw: raw, labelNumber: label), contentModified: f.contentModified)
                : f
        }
    }

    private func reload() {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var out: [ArchiveFile] = []
        out.reserveCapacity(query.resultCount)
        for i in 0..<query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            let name = (item.value(forAttribute: NSMetadataItemFSNameKey) as? String) ?? url.lastPathComponent
            let tagArray = (item.value(forAttribute: "kMDItemUserTags") as? [String]) ?? []
            let label = item.value(forAttribute: "kMDItemFSLabel") as? Int
            let uti = item.value(forAttribute: NSMetadataItemContentTypeKey) as? String
            let modified = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
            out.append(ArchiveFile(
                url: url, name: name, fileType: Self.shortType(uti: uti, url: url),
                tags: DocumentTags.parse(raw: tagArray, labelNumber: label), contentModified: modified))
        }
        files = out
        isGathering = false
    }

    private static func shortType(uti: String?, url: URL) -> String {
        if uti == "com.adobe.pdf" { return "PDF" }
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "File" : ext
    }
}
