import AppKit
import ArchiveCore

/// W47.ct-zotero — what a source block's archive knows about its document: the archival location the chip shows, and
/// the CSL-JSON "Copy for Zotero" puts on the clipboard (`ZoteroExport`, the same export as the Reader's), and what
/// "Add to Zotero" sends to the Zotero on this Mac with the subjects as tags (W47.ct-zotero-tags). It resolves
/// only the exact, already-granted path of a Reader link, as the thumbnail renderer does: a chip never starts a
/// basename walk or asks for a folder. The facts are the linked page's document in the PDF's catalogue record
/// (`CatalogueSourceFacts`, W49.storage-notes-zotero), the same read the Reader's export makes; the note's own front
/// matter is never part of them. Read only; it holds its own short security scope for each read, so it cannot close
/// the visible preview's.
@MainActor
final class SourceArchiveInfo {
    /// Set once by `SourceBlockPreviewState`, which owns the app's root store.
    static var shared: SourceArchiveInfo?

    private let rootStore: ReaderRootStore
    /// The container line by link, for a short while: a chip is rebuilt whenever its note restyles.
    private var lines: [String: (line: String?, at: Date)] = [:]
    static let lineLifetime: TimeInterval = 60

    /// Reads a PDF's embedded catalogue identity; tests pass a fixture reader.
    private let identifyPDF: CatalogueReader.IdentifyPDF

    init(rootStore: ReaderRootStore, identifyPDF: @escaping CatalogueReader.IdentifyPDF = CataloguePDFIdentity.identify) {
        self.rootStore = rootStore
        self.identifyPDF = identifyPDF
    }

    /// The chip's location line ("Hoover Institution Archives · Albert Glotzer Papers · Box 17, Folder 8"); nil when
    /// the source cannot be reached or has no container value.
    func containerLine(for anchor: SourceAnchor) async -> String? {
        guard let link = anchor.link else { return nil }
        if let cached = lines[link], Date().timeIntervalSince(cached.at) < Self.lineLifetime { return cached.line }
        let line = await read(anchor) { pdf, _, lookup in
            Self.containerLine(lookup.shown(for: pdf).mapValues(\.text))
        } ?? nil
        lines[link] = (line, Date())
        return line
    }

    /// Everything gathered for the source, as a CSL-JSON array; nil when the source cannot be reached.
    func zoteroJSON(for anchor: SourceAnchor) async -> Data? {
        await zoteroSources(for: anchor).map { ZoteroExport.export($0) }
    }

    /// Everything gathered for the source (W47.ct-zotero-tags: Add to Zotero sends it): one item for a page link,
    /// one per document for a link to a whole file that holds several; nil when it cannot be reached.
    func zoteroSources(for anchor: SourceAnchor) async -> [ZoteroSource]? {
        let link = anchor.link
        let identify = identifyPDF
        return await read(anchor) { pdf, selection, lookup in
            // An explicit action may walk the granted root once to find a split document's owner.
            let resolution = CatalogueSourceFacts.resolve([selection.occurrence], grantedRoot: selection.root,
                                                          inventoryForForeignOwners: true, identifyPDF: identify)[0]
            return ZoteroSource.gather(resolution, pdf: pdf, container: lookup.shown(for: pdf).mapValues(\.text),
                                       link: link)
        }
    }

    /// The granted root and the exact occurrence a Reader link names.
    struct LinkedOccurrence: Sendable {
        let root: URL
        let occurrence: CatalogueSourceFacts.Selection
    }

    /// Repository, collection and the composed location (`ContainerCSL`'s `archive_location`), joined by ` · `.
    nonisolated static func containerLine(_ shown: [ContainerField: String]) -> String? {
        let location = ContainerCSL(shown: shown).variables["archive_location"]
        let parts = [shown[.repository], shown[.collectionTitle] ?? shown[.collectionNumber], location].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Runs `body` off the main actor on the PDF a Reader link names, inside its granted root, with a container lookup
    /// over the root's tree. Nil when the link is not a Reader link, its root is not granted, or the file is not at
    /// its recorded path.
    private func read<T: Sendable>(_ anchor: SourceAnchor,
                                   _ body: @escaping @Sendable (URL, LinkedOccurrence, ContainerLookup) -> T) async -> T? {
        guard let linkString = anchor.link, let linkURL = URL(string: linkString),
              case .readerReveal(let rootGUID, let relativePath, let page, _) = DurableLink(url: linkURL),
              let rootURL = rootStore.knownRoot(for: rootGUID) else { return nil }
        let startedScope = rootURL.startAccessingSecurityScopedResource()
        defer { if startedScope { rootURL.stopAccessingSecurityScopedResource() } }
        let fileURL = rootURL.appendingPathComponent(relativePath)
        guard ReaderRootContainment.isContained(fileURL, inCanonicalRoot: ReaderRootContainment.canonical(rootURL))
        else { return nil }
        return await Task.detached(priority: .utility) { () -> T? in
            guard FileManager.default.fileExists(atPath: fileURL.standardizedFileURL.path) else { return nil }
            return body(fileURL, LinkedOccurrence(root: rootURL, occurrence: .init(relativePath: relativePath, page: page)),
                        ContainerLookup(treeRoot: ContainerLookup.treeRoot(forGrantedRoot: rootURL)))
        }.value
    }
}
