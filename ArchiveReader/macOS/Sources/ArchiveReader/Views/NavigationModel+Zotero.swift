import AppKit
import ArchiveCore
import UniformTypeIdentifiers

// MARK: - Export to Zotero (W47.ct-zotero; `SPEC/containers.md` §Zotero)
//
// Selection ▸ Export to Zotero… saves one CSL-JSON file for the selected documents, with everything gathered for each
// (`ZoteroExport`): the container as the Container column shows it, the date from its tags, the page-2 header's item
// fields and the people and places in the Processor's sidecar. The archive is only read; the file is saved where the
// user chooses, outside the archive folder, and Zotero takes it with File ▸ Import. Selection ▸ Add to Zotero sends the
// same items, with the subjects as tags, to the Zotero open on this Mac (W47.ct-zotero-tags). A folder that uses
// catalogue companions exports each PDF's catalogue record instead, through the read Notes makes for a source link
// (`CatalogueSourceFacts`, W49.storage-notes-zotero): one item per document, and never an earlier tag, header,
// sidecar or correction in place of a record that cannot be read.

extension NavigationModel {
    /// `paths` nil exports the list's selection; the document window passes its open file, and `report` receives each
    /// status line so its own status bar can show it (W49.reader-doc-window-parity).
    func exportToZotero(paths: [String]? = nil, report: ((String) -> Void)? = nil) {
        let files = tagTargets(paths)
        guard !files.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.zoteroExportName(files.map(\.url))
        panel.message = "Import the file in Zotero with File ▸ Import."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if let refusal = Self.zoteroDestinationRefusal(destination, protecting: zoteroProtectedFolders(files)) {
            statusMessage = refusal
            announce(refusal)
            report?(refusal)
            return
        }
        let gather = zoteroGatherer(files)
        statusMessage = "Exporting \(files.count) document\(files.count == 1 ? "" : "s") for Zotero…"
        report?(statusMessage)
        Task { [weak self] in
            // A file that holds several documents gives one item each (W49.storage-notes-zotero).
            let written: Result<Int, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    let sources = gather()
                    try ZoteroExport.export(sources).write(to: destination, options: .atomic)
                    return sources.count
                }
            }.value
            guard let self else { return }
            switch written {
            case .success(let count):
                self.statusMessage = Self.zoteroExportedMessage(count: count, name: destination.lastPathComponent)
            case .failure(let error):
                self.statusMessage = "Could not save \(destination.lastPathComponent): \(error.localizedDescription)"
            }
            self.announce(self.statusMessage)
            report?(self.statusMessage)
        }
    }

    /// Selection ▸ Add to Zotero (W47.ct-zotero-tags): the same items straight into the Zotero open on this Mac, through
    /// its connector (`ZoteroConnector`), with the subjects as tags, which the CSL-JSON file cannot carry. Zotero saves
    /// them into the library or collection selected in it. Nothing is written on this Mac.
    func addToZotero(paths: [String]? = nil, report: ((String) -> Void)? = nil) {
        let files = tagTargets(paths)
        guard !files.isEmpty else { return }
        let gather = zoteroGatherer(files)
        statusMessage = "Adding \(files.count) document\(files.count == 1 ? "" : "s") to Zotero…"
        report?(statusMessage)
        Task { [weak self] in
            let sources = await Task.detached(priority: .userInitiated) { gather() }.value
            let failure: ZoteroConnector.Failure?
            do { try await ZoteroConnector().save(sources); failure = nil } catch {
                failure = error as? ZoteroConnector.Failure ?? .notRunning
            }
            guard let self else { return }
            self.statusMessage = Self.zoteroAddedMessage(count: sources.count, failure: failure)
            self.announce(self.statusMessage)
            report?(self.statusMessage)
        }
    }

    static func zoteroAddedMessage(count: Int, failure: ZoteroConnector.Failure?) -> String {
        let docs = "\(count) document\(count == 1 ? "" : "s")"
        switch failure {
        case nil:
            return "Added \(docs) to Zotero, with their subjects as tags, in the library or collection selected there."
        case .notRunning:
            return "Zotero is not running on this Mac. Start Zotero and try again, or use Export to Zotero… to save a file."
        case .refused(let status):
            return "Zotero did not add the \(docs) (it answered \(status)). Select a library or collection you can edit in Zotero and try again."
        }
    }

    /// Reads everything for `files` (`ZoteroSource`); call the result off the main thread. The archive is only read.
    func zoteroGatherer(_ files: [ArchiveFile]) -> @Sendable () -> [ZoteroSource] {
        let sources = files.map { file in
            ZoteroSource(fileName: file.url.lastPathComponent, tags: file.tags,
                         container: Self.zoteroContainer(containerCatalog.rows[file.path]))
        }
        let urls = files.map(\.url)
        // A file the catalog has not reached yet (a scan still settling) is read through the same lookup.
        let tree = containerTree?.url
        let catalogueRoot = library.usesCatalogue ? rootStore.root : nil
        // The library's last pass lets a walk for a split document's owner skip every unchanged file's parse.
        let memory = library.catalogueSnapshot?.memory
        return { Self.gatherZotero(sources, urls: urls, tree: tree, catalogueRoot: catalogueRoot, memory: memory) }
    }

    /// The catalogue's sources for `urls` under the granted `root`: each file's record read again from disk, as
    /// Notes reads a source link, with the container as the list shows it. Read only.
    nonisolated static func gatherCatalogueZotero(_ sources: [ZoteroSource], urls: [URL], tree: URL?, root: URL,
                                                  memory: CatalogueReader.ReadMemory? = nil,
                                                  identifyPDF: @escaping CatalogueReader.IdentifyPDF
                                                      = CataloguePDFIdentity.identify) -> [ZoteroSource] {
        let lookup = tree.map(ContainerLookup.init(treeRoot:))
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        let rootPath = CorpusWalker.withDatalessMaterializationDisabled { CorpusWalker.discoveredPathPrefix(for: root) }
            ?? root.standardizedFileURL.path
        let relative = urls.map { ReaderCatalogueScan.relativePath(of: $0, under: rootPath) }
        // An explicit export may walk the root once to find a split document's owner.
        var resolved = CatalogueSourceFacts.resolve(relative.compactMap { $0.map { .init(relativePath: $0) } },
                                                    grantedRoot: root, inventoryForForeignOwners: true,
                                                    memory: memory, identifyPDF: identifyPDF).makeIterator()
        return zip(sources, zip(urls, relative)).flatMap { source, file -> [ZoteroSource] in
            let (url, path) = file
            let resolution = path == nil ? .unavailable(.invalid(.root)) : resolved.next() ?? .unavailable(.invalid(.root))
            let container = source.container.isEmpty ? lookup?.shown(for: url).mapValues(\.text) ?? [:] : source.container
            return ZoteroSource.gather(resolution, pdf: url, container: container)
        }
    }

    /// Fills each source from its file: the container (when the catalog had none), page 2's item fields, the sidecar,
    /// and the user's item-field values (W40.reader-item-field-edit), read once per folder. Read only.
    nonisolated static func gatherZotero(_ sources: [ZoteroSource], urls: [URL], tree: URL?,
                                         catalogueRoot: URL? = nil,
                                         memory: CatalogueReader.ReadMemory? = nil) -> [ZoteroSource] {
        if let catalogueRoot {
            return gatherCatalogueZotero(sources, urls: urls, tree: tree, root: catalogueRoot, memory: memory)
        }
        let lookup = tree.map(ContainerLookup.init(treeRoot:))
        var corrections: [String: UserItemFields?] = [:]
        return zip(sources, urls).map { source, url -> ZoteroSource in
            var s = source
            if s.container.isEmpty, let lookup { s.container = lookup.shown(for: url).mapValues(\.text) }
            s.itemFields = ZoteroSource.headerItemFields(pdf: url)
            s.sidecar = ZoteroSidecar.read(pdf: url)
            let folder = url.deletingLastPathComponent().path
            if corrections[folder] == nil { corrections[folder] = .some(UserItemFields.load(folderOf: url)) }
            s.userItemFields = corrections[folder]??.values(for: url.lastPathComponent) ?? [:]
            return s
        }
    }

    /// The container as the Container column shows it.
    static func zoteroContainer(_ row: ContainerRow?) -> [ContainerField: String] {
        Dictionary(row?.summary.map { ($0.field, $0.text) } ?? [], uniquingKeysWith: { first, _ in first })
    }

    /// The file's name: the document's own for one, else a general one.
    static func zoteroExportName(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent + " (Zotero).json" : "Zotero export.json"
    }

    /// The folders an export may not be saved in: the granted folder and its JPEG folder, the sibling of a main or JPEG
    /// folder granted alone, and the folder of every selected file.
    func zoteroProtectedFolders(_ files: [ArchiveFile]) -> [URL] {
        var folders = files.map { $0.url.deletingLastPathComponent() }
        if let granted = rootStore.root {
            folders.append(granted)
            let layout = ReaderArchiveLayout(grantedRoot: granted)
            folders.append(layout.jpegRoot)
            // The main or JPEG folder granted alone: its sibling (never the whole parent, which may be the home folder).
            if layout.needsCommonParentGrant {
                let parent = granted.deletingLastPathComponent()
                folders.append(parent.appendingPathComponent(ReaderArchiveLayout.mainDirectoryName, isDirectory: true))
                folders.append(parent.appendingPathComponent(ReaderArchiveLayout.jpegDirectoryName, isDirectory: true))
            }
        }
        if let prefix = rootStore.discoveredPathPrefix { folders.append(URL(fileURLWithPath: prefix, isDirectory: true)) }
        return folders
    }

    /// Why the export may not be saved at `destination`: in or under one of `protecting`, the archive's folders, where
    /// the Reader writes nothing but tags (a `.json` there could even take a sidecar's name). Nil when it may.
    static func zoteroDestinationRefusal(_ destination: URL, protecting: [URL]) -> String? {
        // The file does not exist yet, so its folder is the one resolved (a link to the archive is the archive).
        // Compared case-folded: APFS is usually case-insensitive, and refusing one folder too many is safe.
        func resolved(_ url: URL) -> String {
            (CorpusWalker.discoveredPathPrefix(for: url) ?? url.standardizedFileURL.path).lowercased()
        }
        let folder = resolved(destination.deletingLastPathComponent())
        let inside = protecting.contains { protected in
            let root = resolved(protected)
            return folder == root || ReaderArchiveLayout.isContained(path: folder, underRootPath: root)
        }
        return inside ? "Save the Zotero export outside the archive folder." : nil
    }

    static func zoteroExportedMessage(count: Int, name: String) -> String {
        "Saved \(count) document\(count == 1 ? "" : "s") for Zotero in “\(name)”. In Zotero, choose File ▸ Import."
    }
}
