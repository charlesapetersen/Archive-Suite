// DeepLinkRouter.swift — parse + dispatch archivereader:// URLs
// Part of Archive Reader (W4-S3).

import Foundation
import ArchiveCore

/// Parses incoming `archivereader://reveal` URLs and dispatches them to
/// `NavigationModel.revealAndSelect`.
@MainActor
final class DeepLinkRouter: ObservableObject {
    weak var nav: NavigationModel?

    func handle(_ url: URL) {
        guard case .readerReveal(let guid, let rel, let page) = DurableLink(url: url) else {
            return
        }
        nav?.revealAndSelect(rootGUID: guid, relativePath: rel, page: page)
    }
}
