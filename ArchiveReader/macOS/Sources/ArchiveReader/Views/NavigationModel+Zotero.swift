import AppKit
import ArchiveCore
import UniformTypeIdentifiers

// MARK: - Export to Zotero (W47.ct-zotero; `SPEC/containers.md` §Zotero)
//
// Selection ▸ Export to Zotero… saves one CSL-JSON file for the selected documents, with everything gathered for each
// (`ZoteroExport`): the container as the Container column shows it, the date from its tags, the page-2 header's item
// fields and the people and places in the Processor's sidecar. The archive is only read; the file is saved where the
// user chooses, outside the archive folder, and Zotero takes it with File ▸ Import.

extension NavigationModel {
    func exportToZotero() {
        let files = selectedFiles
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
            return
        }
        let sources = files.map { file in
            ZoteroSource(fileName: file.url.lastPathComponent, tags: file.tags,
                         container: Self.zoteroContainer(containerCatalog.rows[file.path]))
        }
        let urls = files.map(\.url)
        // A file the catalog has not reached yet (a scan still settling) is read through the same lookup.
        let tree = containerTree?.url
        statusMessage = "Exporting \(files.count) document\(files.count == 1 ? "" : "s") for Zotero…"
        Task { [weak self] in
            let written: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                let lookup = tree.map(ContainerLookup.init(treeRoot:))
                let full = zip(sources, urls).map { source, url -> ZoteroSource in
                    var s = source
                    if s.container.isEmpty, let lookup { s.container = lookup.shown(for: url).mapValues(\.text) }
                    s.itemFields = ZoteroSource.headerItemFields(pdf: url)
                    s.sidecar = ZoteroSidecar.read(pdf: url)
                    return s
                }
                return Result { try ZoteroExport.export(full).write(to: destination, options: .atomic) }
            }.value
            guard let self else { return }
            switch written {
            case .success:
                self.statusMessage = Self.zoteroExportedMessage(count: urls.count, name: destination.lastPathComponent)
            case .failure(let error):
                self.statusMessage = "Could not save \(destination.lastPathComponent): \(error.localizedDescription)"
            }
            self.announce(self.statusMessage)
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
