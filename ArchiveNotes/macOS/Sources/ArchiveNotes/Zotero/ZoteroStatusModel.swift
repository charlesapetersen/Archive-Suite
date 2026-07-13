import SwiftUI
import AppKit

/// Bridges the off-main `ZoteroClient` actor to SwiftUI and surfaces a
/// clipboard-detected Zotero link to the UI (00-overview §D.5).
///
/// Never blocks: availability is refreshed on a cancellable `Task`; clipboard
/// detection is a pure, synchronous parse. The pasteboard is only re-read when
/// the caller asks (on editor appear / app-activate) — there is **no** background
/// timer — and a `changeCount` gate skips redundant parses.
@MainActor
final class ZoteroStatusModel: ObservableObject {

    /// Last known backend. Drives whether the (S5) "auto-fill" affordance is offered;
    /// link-only attach + chip-open are always available regardless of this value.
    @Published private(set) var backend: ZoteroClient.Backend = .unavailable

    /// A recognized, not-yet-attached zotero link currently on the clipboard
    /// (`nil` = nothing to offer).
    @Published private(set) var clipboardRef: ZoteroRef?

    private let client: ZoteroClient
    private var availabilityTask: Task<Void, Never>?
    private var lastChangeCount = -1

    init(client: ZoteroClient = ZoteroClient()) {
        self.client = client
    }

    /// Refresh backend availability off the main actor. Cancels any in-flight probe
    /// so rapid re-triggers coalesce to the latest result.
    func refreshAvailability() {
        availabilityTask?.cancel()
        // Integration disabled (Options ▸ Zotero) → never probe; report unavailable so the
        // auto-fill affordance stays hidden. Link attach + chip-open remain available regardless.
        guard ZoteroSettingsStore.current.enabled else {
            backend = .unavailable
            return
        }
        availabilityTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.client.availability()
            if Task.isCancelled { return }
            self.backend = result
        }
    }

    /// Re-read the pasteboard and update `clipboardRef`. Cheap + synchronous; skips
    /// work when the pasteboard hasn't changed since the last read.
    /// - Parameter attachedLinks: canonical select links already attached (deduped out).
    func refreshClipboard(attachedLinks: Set<String> = []) {
        // Detection off, or the whole integration disabled → never surface a banner.
        let settings = ZoteroSettingsStore.current
        guard settings.enabled, settings.clipboardDetect else {
            if clipboardRef != nil { clipboardRef = nil }
            return
        }
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == lastChangeCount { return }
        lastChangeCount = pasteboard.changeCount
        let string = pasteboard.string(forType: .string)
        clipboardRef = ZoteroClipboardDetect.detect(pasteboardString: string,
                                                     attachedLinks: attachedLinks)
    }

    /// Clear the detected clipboard link (after the user attaches or dismisses it).
    func dismissClipboardRef() {
        clipboardRef = nil
    }
}
