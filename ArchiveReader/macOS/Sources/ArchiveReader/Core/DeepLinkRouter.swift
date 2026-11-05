// DeepLinkRouter.swift — parse + dispatch archivereader:// URLs
// Part of Archive Reader (W4-S3).

import Foundation
import ArchiveCore

/// Parses incoming `archivereader://reveal` URLs and dispatches them to
/// `NavigationModel.revealAndSelect`.
@MainActor
final class DeepLinkRouter: ObservableObject {
    weak var nav: NavigationModel? {
        didSet { if let nav, chooseRootPending { runPendingChooseRoot(on: nav) } }
    }

    /// W40.fix-reader-choose-folder-shortcut: File ▸ Choose Archive Folder… (⇧⌘O) works from any Reader
    /// window, not only the navigation window. The menu opens the navigation window first; the panel then
    /// runs on that window's model once it is attached, which is at once when the window was only behind
    /// another, and at its `onAppear` when it had been closed.
    private(set) var chooseRootPending = false
    /// What runs the panel; tests replace it, since `NSOpenPanel.runModal` cannot run in a unit-test host.
    var chooseRootAction: (NavigationModel) -> Void = { $0.chooseRoot() }

    func requestChooseRoot(openNavigationWindow: () -> Void) {
        chooseRootPending = true
        openNavigationWindow()
        // A turn of the run loop lets the window come forward before the modal panel starts; a model
        // that attaches in the meantime has already run it through `nav`'s `didSet`.
        DispatchQueue.main.async { [weak self] in
            guard let self, let nav = self.nav, self.chooseRootPending else { return }
            self.runPendingChooseRoot(on: nav)
        }
    }

    private func runPendingChooseRoot(on nav: NavigationModel) {
        chooseRootPending = false
        let action = chooseRootAction
        DispatchQueue.main.async { action(nav) }
    }

    func handle(_ url: URL) {
        guard case .readerReveal(let guid, let rel, let page, let jpeg) = DurableLink(url: url) else {
            return
        }
        nav?.revealAndSelect(rootGUID: guid, relativePath: rel, page: page, jpegRelativePath: jpeg)
    }
}
