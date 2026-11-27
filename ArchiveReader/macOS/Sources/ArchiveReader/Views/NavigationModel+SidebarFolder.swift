import AppKit

/// The sidebar folder's right-click menu (W49.reader-ux-gaps-small): Reveal in Finder, Exclude Folder and
/// Container Levels for the folder clicked, which before were reachable only through Settings or File.
extension NavigationModel {
    /// Shows the folder in Finder. Read-only: opens a Finder window on it, changes nothing.
    func revealFolderInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    /// Adds the folder to Settings ▸ Excluded folders. A list scoped to it, or to a folder inside it, goes back to
    /// All Files, since its files leave the list.
    func excludeFolder(_ path: String) {
        guard let rootPath = rootStore.discoveredPathPrefix else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let placement = ExcludedFoldersStore.placement(of: path, rootPath: rootPath)
        guard case let .inside(relative) = placement else {
            statusMessage = ExcludedFoldersStore.refusal(placement, folderName: name,
                                                         rootName: URL(fileURLWithPath: rootPath).lastPathComponent) ?? ""
            announce(statusMessage)
            return
        }
        if scope == nil, let shown = filter.pathPrefix, shown == path || shown.hasPrefix(path + "/") {
            setFolderScope(nil)
        }
        excludedFolders.add(relative)
        statusMessage = "Excluded “\(name)”. Its files are hidden until it is removed in Settings ▸ Excluded folders."
        announce(statusMessage)
    }

    /// File ▸ Container Levels… for the folder: the list goes to it first, as clicking it would, so the sheet opens
    /// on that folder.
    func openContainerLevels(forFolder path: String) {
        setFolderScope(path)
        openContainerLevels()
    }
}
