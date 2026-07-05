import SwiftUI

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
    var body: some Scene {
        Window("Archive Reader", id: WindowID.navigation) {
            NavigationWindowView()
        }
        .commands { ArchiveReaderCommands() }

        WindowGroup(id: WindowID.document, for: DocumentSelection.self) { $selection in
            DocumentWindowView(selection: selection)
        }

        Settings {
            OptionsView()
        }
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
