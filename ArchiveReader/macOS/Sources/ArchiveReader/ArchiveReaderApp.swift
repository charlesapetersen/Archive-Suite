import SwiftUI
import AppKit
import ArchiveCore

/// Archive Reader — a native macOS app for reading & triaging tagged historical-document PDFs.
///
/// Two windows (see PLAN.md): a single **navigation** window (Finder-Smart-Folder-like browser) and
/// **document** windows opened with a user-chosen selection of files. Settings via ⌘,.
///
/// SAFETY: this app never deletes, moves, renames, or alters any file's bytes/location. The only
/// mutation it performs is editing macOS Finder tags, exclusively through `TagWriter` (see CLAUDE.md
/// → Safety Protocol). The write path is not yet present — this is the read-only foundation.
@main
struct ArchiveReaderApp: App {
    // Observed so a size change (persisted on window close) re-evaluates `documentDefaultSize`, and the
    // next document window OPENS at that size — no open-small-then-resize flash (DV-1).
    @AppStorage(SettingsKey.viewerWinW) private var viewerWinW = 0.0
    @AppStorage(SettingsKey.viewerWinH) private var viewerWinH = 0.0

    @StateObject private var deepLinkRouter = DeepLinkRouter()

    /// Demote the process when it is only acting as a unit-test host, so `xcodebuild test
    /// -only-testing:ArchiveReaderTests` never takes the owner's screen (→ `ArchiveTestHost`).
    init() { MainActor.assumeIsolated { ArchiveTestHost.suppressWindowsIfUnitTestHost() } }

    var body: some Scene {
        // Under a unit-test host the navigation window renders `HiddenWindowStub` instead of its real
        // content, so nothing reaches the owner's screen (→ `ArchiveTestHost`). The branch has to live
        // here in the `ViewBuilder` rather than around the scenes: `SceneBuilder` has no `buildEither`,
        // so a conditional at scene level doesn't compile. The document `WindowGroup` below needs no
        // guard — it never auto-opens at launch.
        Window("Archive Reader", id: WindowID.navigation) {
            if ArchiveTestHost.isUnitTestHost {
                ArchiveTestHost.HiddenWindowStub()
            } else {
                NavigationWindowView()
                    .environmentObject(deepLinkRouter)
                    .onOpenURL { url in
                        NSApp.activate(ignoringOtherApps: true)
                        deepLinkRouter.handle(url)
                    }
            }
        }
        .commands { ArchiveReaderCommands() }

        WindowGroup(id: WindowID.document, for: DocumentSelection.self) { $selection in
            DocumentWindowView(selection: selection)
        }
        .defaultSize(documentDefaultSize)   // DV-1: open at the remembered size (or the full screen) — no post-show resize flash

        Settings {
            OptionsView()
        }
    }

    /// The document window's initial size: the user's last-remembered size (tracked via @AppStorage so
    /// this re-evaluates when it changes), else the full screen.
    private var documentDefaultSize: CGSize {
        (viewerWinW > 200 && viewerWinH > 200)
            ? CGSize(width: viewerWinW, height: viewerWinH)
            : (NSScreen.main?.visibleFrame.size ?? CGSize(width: 1400, height: 900))
    }
}

enum WindowID {
    static let navigation = "navigation"
    static let document = "document"
}

/// The payload that opens a document window: the files the user chose to read together.
/// The user decides grouping (the app never auto-groups). Carries paths for now; will carry
/// stable, security-scoped bookmark identity as the file layer matures.
struct DocumentSelection: Codable, Hashable {
    var filePaths: [String]
}
