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

    func configureContentIndex(for root: URL?) {
        let scope: ReaderRootCacheScope?
        if let root, let marker = rootStore.rootMarker, let rootPath = rootStore.discoveredPathPrefix,
           let identity = ReaderRootIdentity.capture(root) {
            scope = ReaderRootCacheScope(markerGUID: marker.guid, identity: identity, rootPath: rootPath)
        } else {
            scope = nil
        }
        indexer.setRootCache(scope)
    }

    func startLibrary(_ url: URL) {
        configureContentIndex(for: url)
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
        refreshCatalogueEditHistory()
        refreshFullTextSearchIfActive()
    }

    private func catalogueInstance(for root: URL) -> UUID? {
#if DEBUG
        // An explicit fixture root never reads or saves a real archive's mode.
        if defaults.string(forKey: "ARUITestRootPath") != nil {
            return defaults.bool(forKey: "ARUITestCatalogue")
                ? UUID(uuidString: "7AF0E743-A085-4200-A2F4-FA7304C54A63")
                : nil
        }
#endif
        guard let key = cataloguePreferenceKey(for: root),
              defaults.bool(forKey: key + ".enabled") else { return nil }
        return defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    private func cataloguePreferenceKey(for root: URL) -> String? {
        // Preserve the in-place setting on filesystems without a usable directory birth time.
        guard let identity = ReaderRootIdentity.capture(root) else {
            return ReaderRootIdentity.legacyCatalogueKey(for: root)
        }
        let key = "readerCatalogue.instance.\(identity.key)"
        restoreCataloguePreference(for: identity, key: key)
        return key
    }

    /// Keep the existing instance ID when reopening an adopted root at its previous path.
    private func restoreCataloguePreference(for identity: ReaderRootIdentity, key: String) {
        let prior = identity.previousCatalogueKey
        guard defaults.string(forKey: key) == nil,
              let existing = defaults.string(forKey: prior), UUID(uuidString: existing) != nil else { return }
        defaults.set(existing, forKey: key)
        defaults.set(defaults.bool(forKey: prior + ".enabled"), forKey: key + ".enabled")
    }
}
