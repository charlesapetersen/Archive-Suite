import AppKit
import ArchiveCore

// MARK: - Export with Catalogue Records (W49.storage-export; `SPEC/catalogue.md` §"Pair and subset export")
//
// Selection ▸ Export with Catalogue Records… copies the selected PDFs with their catalogue companions into a new
// folder the user names, outside the archive, with what their documents depend on: the rest of a split document, the
// covering document of an enclosure, the preserved originals and the folder records the container comes from
// (`CatalogueExport`). Copying that folder anywhere keeps the current facts, which a PDF copied alone does not. The
// archive is only read. The folder is a dated snapshot: later edits in the archive do not change it.

extension NavigationModel {
    /// `paths` nil exports the list's selection; the document window passes its open file.
    func exportWithCatalogue(paths: [String]? = nil, report: ((String) -> Void)? = nil) {
        let files = tagTargets(paths)
        guard !files.isEmpty else { return }
        guard library.usesCatalogue, let root = rootStore.root else {
            let refusal = Self.catalogueExportNotCatalogued
            statusMessage = refusal
            announce(refusal)
            report?(refusal)
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = Self.catalogueExportName(files.map(\.url))
        panel.message = "A new folder with the PDFs and their catalogue records, including read state, flags and checks."
        panel.prompt = "Export"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if Self.zoteroDestinationRefusal(destination, protecting: zoteroProtectedFolders(files)) != nil {
            let refusal = Self.catalogueExportInsideArchive
            statusMessage = refusal
            announce(refusal)
            report?(refusal)
            return
        }
        let urls = files.map(\.url)
        statusMessage = "Exporting \(files.count) document\(files.count == 1 ? "" : "s") with their catalogue records…"
        report?(statusMessage)
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Self.exportCatalogue(urls, root: root, to: destination)
            }.value
            guard let self else { return }
            self.statusMessage = Self.catalogueExportMessage(result, name: destination.lastPathComponent)
            self.announce(self.statusMessage)
            report?(self.statusMessage)
        }
    }

    /// The export itself, off the main thread: `urls` under the granted `root`, read only, into a new `destination`.
    nonisolated static func exportCatalogue(_ urls: [URL], root: URL, to destination: URL,
                                            identifyPDF: @escaping CatalogueReader.IdentifyPDF = CataloguePDFIdentity.identify)
        -> Result<CatalogueExport.Manifest, Error> {
        let scoped = root.startAccessingSecurityScopedResource()
        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
        return Result {
            let rootPath = CorpusWalker.withDatalessMaterializationDisabled { CorpusWalker.discoveredPathPrefix(for: root) }
                ?? root.standardizedFileURL.path
            var relative: [String] = []
            for url in urls {
                guard let path = ReaderCatalogueScan.relativePath(of: url, under: rootPath) else {
                    throw CatalogueExport.Failure.unavailable(path: url.lastPathComponent, .invalid(.root))
                }
                relative.append(path)
            }
            let reader = try CatalogueReader(grantedRoot: root, rootInstanceID: UUID(), mode: .adopted, identifyPDF: identifyPDF)
            return try CatalogueExport.export(relative, from: reader, to: destination)
        }
    }

    static let catalogueExportNotCatalogued =
        "This folder does not use catalogue records yet, so there are none to export. Copy the PDFs in Finder instead."
    static let catalogueExportInsideArchive = "Choose a place outside the archive folder for the export."

    /// The folder's name: the document's own for one, else a general one.
    static func catalogueExportName(_ urls: [URL]) -> String {
        urls.count == 1 ? urls[0].deletingPathExtension().lastPathComponent + " (with catalogue)" : "Catalogue export"
    }

    static func catalogueExportMessage(_ result: Result<CatalogueExport.Manifest, Error>, name: String) -> String {
        switch result {
        case .success(let manifest):
            let selected = manifest.files.filter { $0.role == .selected }.count
            let added = manifest.files.count - selected
            let docs = "\(selected) document\(selected == 1 ? "" : "s")"
            let extra = added == 0 ? "" : ", with \(added) more file\(added == 1 ? "" : "s") their records depend on,"
            return "Exported \(docs)\(extra) to “\(name)”. Copy the whole folder to keep the catalogue facts."
        case .failure(let error):
            return "Nothing was exported: \(error.localizedDescription)"
        }
    }
}
