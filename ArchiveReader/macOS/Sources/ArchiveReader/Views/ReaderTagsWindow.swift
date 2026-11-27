import SwiftUI
import Combine
import ArchiveCore
import ArchiveCoreUI

/// Window ▸ Tags (W40.tag-window-reader): the suite's shared Tags window (ArchiveCoreUI `TagsWindowView`) over the
/// navigation window's library. Every subject in use with its file count; Rename, Merge and Remove write through
/// `NavigationModel.applyTagPlan` (TagWriter, one Undo, recorded for the other apps); Show Files filters the
/// navigation list to the tag. With this window in front, Edit ▸ Undo and Redo act on the same library
/// (`tagsWindowNavigation`). The window itself writes nothing.
struct ReaderTagsWindow: View {
    @EnvironmentObject private var router: DeepLinkRouter

    var body: some View {
        if let nav = router.nav {
            ReaderTagsWindowContent(nav: nav, model: nav.tagsWindow)
        } else {
            Text("Open a folder in the Archive Reader window to see its tags here.")
                .foregroundStyle(.secondary)
                .frame(minWidth: 460, minHeight: 360)
        }
    }
}

private struct ReaderTagsWindowContent: View {
    let nav: NavigationModel
    let model: TagsWindowModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TagsWindowView(model: model) {
            OtherAppsChanges(nav: nav) {
                openWindow(id: WindowID.navigation)
                nav.showingTagChanges = true
            }
        }
        .focusedSceneValue(\.tagsWindowNavigation, nav)
        .onAppear { [nav, model, openWindow] in
            // Weak: the model is the navigation model's own.
            model.showItems = { [weak nav] entry in
                nav?.showFiles(withTag: entry.name)
                openWindow(id: WindowID.navigation)
            }
            nav.refreshTagsWindow()
            Task { await nav.refreshTagChangeInbox() }
        }
        // Every change to the library, the window's own included, rebuilds the list off the main actor.
        .onReceive(nav.library.$filesRevision.dropFirst()) { _ in nav.refreshTagsWindow() }
        .accessibilityIdentifier("ar.tagsWindow")
    }
}

/// Tag Changes from Other Apps, as a section of the window: how many wait, and the sheet that applies them.
private struct OtherAppsChanges: View {
    @ObservedObject var nav: NavigationModel
    let review: () -> Void

    var body: some View {
        let waiting = nav.tagChangeOffers.count
        if waiting > 0 {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                Text(waiting == 1 ? "1 tag change from another app is waiting."
                                  : "\(waiting) tag changes from other apps are waiting.")
                Spacer()
                Button("Review…", action: review)
                    .accessibilityIdentifier("ar.tagsWindow.tagChanges")
            }
            .padding(10)
            Divider()
        }
    }
}
