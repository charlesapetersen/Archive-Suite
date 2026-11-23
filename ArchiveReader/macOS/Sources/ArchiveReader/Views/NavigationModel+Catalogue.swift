import ArchiveCore
import Foundation

extension NavigationModel {
    var catalogueReader: CatalogueReader? { library.catalogueReader }
    var catalogueSnapshot: CatalogueReader.Snapshot? { library.catalogueSnapshot }

    func catalogueFacts(for row: ArchiveFile, physicalPageIndex: Int? = nil) -> ItemFacts? {
        guard row.isCatalogue else { return nil }
        guard let physicalPageIndex else { return row.catalogueFacts }
        guard let rootPath = rootStore.discoveredPathPrefix,
              let relative = ReaderCatalogueScan.relativePath(of: row.url, under: rootPath) else { return nil }
        return catalogueSnapshot?.facts(at: relative, physicalPageIndex: physicalPageIndex)
    }

    func resolvedLibraryRoot(_ url: URL) -> ResolvedLibraryRoot {
        ResolvedLibraryRoot(url: url, markerGUID: rootStore.rootMarker?.guid,
                            catalogueInstance: catalogueInstance(for: url))
    }

    func startLibrary(_ url: URL) {
        let resolved = resolvedLibraryRoot(url)
        library.start(scope: url, markerGUID: resolved.markerGUID, catalogueInstance: resolved.catalogueInstance)
    }

    func setCatalogueMode(_ enabled: Bool) {
        guard let root = rootStore.root, let key = cataloguePreferenceKey(for: root) else { return }
        defaults.set(enabled, forKey: key + ".enabled")
        if defaults.string(forKey: key) == nil {
            defaults.set(UUID().uuidString, forKey: key)
        }
        startLibrary(root)
    }

    private func catalogueInstance(for root: URL) -> UUID? {
        guard let key = cataloguePreferenceKey(for: root) else { return nil }
#if DEBUG
        // An explicit fixture root never reads or saves a real archive's mode.
        if defaults.string(forKey: "ARUITestRootPath") != nil {
            return defaults.bool(forKey: "ARUITestCatalogue")
                ? UUID(uuidString: "7AF0E743-A085-4200-A2F4-FA7304C54A63")
                : nil
        }
#endif
        guard defaults.bool(forKey: key + ".enabled") else { return nil }
        return defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    /// A copied marker or a different directory mounted at the same path cannot inherit this choice.
    private func cataloguePreferenceKey(for root: URL) -> String? {
        CorpusWalker.withDatalessMaterializationDisabled {
            guard let stamp = CorpusRootFingerprint.capture(root) else { return nil }
            return "readerCatalogue.\(stamp.filesystemID).\(stamp.deviceID).\(stamp.inode).\(root.path)"
        }
    }
}
