import AppKit

/// The single choke-point through which Archive Notes dispatches an *external* URL — a Reader
/// `archivereader://reveal?…` deep link (source-block "Reveal in Reader") or a `zotero://select/…`
/// link (source-block "Open in Zotero"). Every production call opens via `NSWorkspace` exactly as
/// before; the only added behaviour is DEBUG-only and UITest-gated (below).
///
/// Why a choke-point: the G6 (reveal → Reader) and G11 (Zotero chip open) GUI checks must assert that
/// the app dispatched the RIGHT URL *without* actually launching Reader / Zotero mid-test (the real
/// external round-trip is owner-eye, and Zotero may not even be installed on the run machine). Under a
/// UITest launch (`-ANUITestStorePath`) the open is RECORDED by `WorkspaceOpenSpy` and NOT dispatched,
/// so the harness reads back the URL through a hidden control-strip element. Compiled-in for every
/// config, but the record-and-skip branch is `#if DEBUG` + `-ANUITestStorePath`-gated, so a normal
/// DEBUG run and Release both open for real.
@MainActor
func openExternalURL(_ url: URL) {
    #if DEBUG
    if WorkspaceOpenSpy.shared.isActive {
        WorkspaceOpenSpy.shared.record(url)
        return
    }
    #endif
    NSWorkspace.shared.open(url)
}

#if DEBUG
/// DEBUG-only recorder for external `NSWorkspace.open(_:)` dispatches, so the G6/G11 GUI checks can
/// assert the dispatched `archivereader://reveal?…` / `zotero://select/…` URL. Active ONLY under a
/// UITest launch (`-ANUITestStorePath`, mirroring the `RootFolderStore` / `NoteEditorPane` gate); a
/// normal DEBUG run leaves `isActive` false so `openExternalURL` opens for real. Compiled out of Release.
@MainActor
final class WorkspaceOpenSpy {
    static let shared = WorkspaceOpenSpy()
    private init() {}

    /// The `absoluteString` of the most recently dispatched external URL (nil until the first open).
    private(set) var lastOpenedURL: String?

    /// True only in a UITest harness launch. Same gate as `NoteEditorPane.isUITestHarness`.
    var isActive: Bool {
        if let p = UserDefaults.standard.string(forKey: "ANUITestStorePath"), !p.isEmpty { return true }
        return false
    }

    func record(_ url: URL) { lastOpenedURL = url.absoluteString }
}
#endif
