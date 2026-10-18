// ArchiveLinkTarget.swift — what a durable archive link needs, made reachable from ANY window.
// Part of Archive Reader (W23.m4).

import SwiftUI
import ArchiveCore

/// The granted root and display identity, shared with every viewer before the first link copy.
/// The optional marker becomes durable only when an explicit copy prepares the root identity.
///
/// Both live on `NavigationModel.rootStore`, which only the *navigation* window owns — so before
/// W23.m4 the "Copy Archive Link to This Page" command required a focused `NavigationModel` and was
/// therefore **disabled in the document window**, i.e. exactly where a reader is looking at the page
/// they want to cite. Publishing this small value as a focused value instead means the command needs
/// only the focused viewer, and works in every window that reads a document.
struct ArchiveLinkTarget: Equatable, Sendable {
    /// The root as a **path prefix**, spelled the way discovery reports the files it will be stripped
    /// from (`RootFolderStore.discoveredPathPrefix`). Deliberately not the root URL: the only use is
    /// prefix arithmetic against a discovered path, and under a root whose spelling differs from its
    /// resolved one the URL's own spelling matches nothing the walk produced — every link silently
    /// degraded to a bare `lastPathComponent`, which resolves in no other archive. It carries no
    /// security scope and must never be opened. (`W26.symroot-fu1`.)
    let rootPath: String
    let marker: RootMarker?
    /// Container-only display preference ID. Never a substitute for a durable link marker.
    let preferenceGUID: UUID
    /// The scanned MAIN subtree used to resolve a partner by the same relative path/stem context.
    let mainRootPath: String

    init(rootPath: String, marker: RootMarker?, mainRootPath: String, preferenceGUID: UUID? = nil) {
        self.rootPath = rootPath
        self.marker = marker
        self.mainRootPath = mainRootPath
        // Production supplies the root store's stable container ID, including before first copy.
        self.preferenceGUID = preferenceGUID ?? marker?.guid ?? UUID()
    }
}

/// App-level carrier for the current `ArchiveLinkTarget`, injected into both scenes so a document
/// window (a separate scene with no `NavigationModel`) can publish the same target the navigation
/// window does. The navigation window is the single writer — it mirrors its `RootFolderStore` here
/// whenever the granted root or its marker changes — so there is exactly one source of truth and a
/// root switch can never leave a document window citing the old archive.
@MainActor
final class ArchiveLinkContext: ObservableObject {
    @Published private(set) var target: ArchiveLinkTarget?
    @Published private(set) var jpegPartnerIndex: JPEGPartnerIndex?

    /// Live preparation, owned by NavigationModel; invoked only by the explicit copy command.
    var prepareForCopy: ((URL) -> ArchiveLinkTarget?)?
    var copyFailureMessage: (() -> String)?

    /// Mirror the navigation root and clean partner scan. A markerless root still publishes a
    /// target so its first copy is enabled; preparation reports damaged/unreadable identities.
    func update(rootPath: String?, marker: RootMarker?, mainRootPath: String?, jpegRootPath: String?,
                jpegPartnerIndex: JPEGPartnerIndex?, preferenceGUID: UUID? = nil) {
        let new: ArchiveLinkTarget?
        if let rootPath, marker != nil || preferenceGUID != nil, let mainRootPath, let jpegRootPath,
           let jpegPartnerIndex, jpegPartnerIndex.isClean,
           jpegPartnerIndex.jpegRootPath == jpegRootPath {
            new = ArchiveLinkTarget(rootPath: rootPath, marker: marker,
                                    mainRootPath: mainRootPath, preferenceGUID: preferenceGUID)
        } else {
            new = nil
        }
        if new != target { target = new }   // guard the publish: called from view updates
        self.jpegPartnerIndex = jpegPartnerIndex?.isClean == true ? jpegPartnerIndex : nil
    }
}

// The focused value the menu commands read. Each window that can show a document publishes it, so
// `ArchiveReaderCommands` never has to reach for a `NavigationModel` it may not have.
struct ArchiveLinkContextKey: FocusedValueKey { typealias Value = ArchiveLinkContext }
extension FocusedValues {
    var archiveLinkContext: ArchiveLinkContext? {
        get { self[ArchiveLinkContextKey.self] }
        set { self[ArchiveLinkContextKey.self] = newValue }
    }
}
