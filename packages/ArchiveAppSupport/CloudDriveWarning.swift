import AppKit
import ArchiveCore
import FileProvider

/// Shared by the two macOS apps. Probes only the selected URLs and their ancestors.
@MainActor
enum CloudDriveWarning {
    private static let seenKey = "hasSeenCloudDriveWarning"
    private static let risks = "Cloud drives may download many files at once, create conflicting copies, or lose Finder tags. Use a folder on this Mac outside any cloud drive."

    static func showAtFirstLaunch(
        testLaunch: Bool,
        title: String = "Keep archive material on this Mac"
    ) {
        let defaults: UserDefaults
#if DEBUG
        // UI tests can exercise the acknowledgement and relaunch with their own defaults.
        if let suite = ProcessInfo.processInfo.environment["ARCHIVE_CLOUD_WARNING_TEST_SUITE"] {
            guard let isolated = UserDefaults(suiteName: suite) else { return }
            defaults = isolated
        } else if testLaunch {
            return
        } else {
            defaults = .standard
        }
#else
        defaults = .standard
#endif
        guard !defaults.bool(forKey: seenKey) else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = "Keep the material you use with this app out of iCloud Drive, OneDrive, Google Drive, Dropbox, and other cloud drives. " + risks
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            defaults.set(true, forKey: seenKey)
        }
    }

    /// Ask before the caller opens, scans, or adopts the selection.
    static func confirmUse(of urls: [URL]) async -> Bool {
        let selected = await firstCloudSelection(in: urls)
        guard !Task.isCancelled else { return false }
        guard let url = selected else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This selection is in a cloud drive"
        alert.informativeText = "“\(url.lastPathComponent)” is stored in a cloud drive. " + risks
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Use Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func firstCloudSelection(in urls: [URL]) async -> URL? {
        var checked = Set<URL>()
        for url in urls where url.isFileURL {
            // Check the picked URL itself (which may carry access from the picker) and any resolved
            // target. An item may lack its own File Provider identifier before it has synced.
            let resolved = CorpusWalker.withDatalessMaterializationDisabled { url.resolvingSymlinksInPath() }
            for start in [url, resolved] {
                var candidate = start
                while !Task.isCancelled, candidate.path != "/", checked.insert(candidate).inserted {
                    if await isCloudManaged(candidate) { return url }
                    candidate = candidate.deletingLastPathComponent()
                }
            }
        }
        return nil
    }

    private static func isCloudManaged(_ url: URL) async -> Bool {
        let ubiquitous = CorpusWalker.withDatalessMaterializationDisabled {
            (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
        }
        if ubiquitous { return true }
#if DEBUG
        if ProcessInfo.processInfo.environment["ARCHIVE_CLOUD_WARNING_TEST_PATH"] == url.path { return true }
#endif
        // macOS provides these identifiers for managed items, including fully downloaded ones.
        return (try? await NSFileProviderManager.identifierForUserVisibleFile(at: url)) != nil
    }
}
