// ArchiveLinkTarget.swift — what a durable archive link needs, made reachable from ANY window.
// Part of Archive Reader (W23.m4).

import SwiftUI
import ArchiveCore

/// Everything needed to write a durable `archivereader://reveal` link: the granted archive **root**
/// (to make the file path root-relative) and its **marker** (whose GUID makes the link portable).
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
    let marker: RootMarker
}

/// App-level carrier for the current `ArchiveLinkTarget`, injected into both scenes so a document
/// window (a separate scene with no `NavigationModel`) can publish the same target the navigation
/// window does. The navigation window is the single writer — it mirrors its `RootFolderStore` here
/// whenever the granted root or its marker changes — so there is exactly one source of truth and a
/// root switch can never leave a document window citing the old archive.
@MainActor
final class ArchiveLinkContext: ObservableObject {
    @Published private(set) var target: ArchiveLinkTarget?

    /// Mirror the navigation window's root store. A missing root or unreadable marker clears the
    /// target (the command then disables) rather than leaving a stale one behind.
    func update(rootPath: String?, marker: RootMarker?) {
        let new = (rootPath != nil && marker != nil)
            ? ArchiveLinkTarget(rootPath: rootPath!, marker: marker!) : nil
        if new != target { target = new }   // guard the publish: called from view updates
    }
}

// The focused value the menu commands read. Each window that can show a document publishes it, so
// `ArchiveReaderCommands` never has to reach for a `NavigationModel` it may not have.
struct ArchiveLinkTargetKey: FocusedValueKey { typealias Value = ArchiveLinkTarget }
extension FocusedValues {
    var archiveLinkTarget: ArchiveLinkTarget? {
        get { self[ArchiveLinkTargetKey.self] }
        set { self[ArchiveLinkTargetKey.self] = newValue }
    }
}
