import SwiftUI
import AppKit
import ArchiveCore

/// The Options panel (⌘,). Settings persist via `@AppStorage`; the models read them through
/// `AppSettings` at point of use, so changes take effect on the next action.
struct OptionsView: View {
    @AppStorage(SettingsKey.linkFormat) private var linkFormat: LinkFormat = .fileURL
    @AppStorage(SettingsKey.linkNewlines) private var linkNewlines: Int = 1
    @AppStorage(SettingsKey.copyCollapse) private var copyCollapse: Bool = true
    @AppStorage(SettingsKey.copyParagraph) private var copyParagraph: Bool = true
    @AppStorage(SettingsKey.copyDehyphenate) private var copyDehyphenate: Bool = true
    @AppStorage(SettingsKey.viewerSplit) private var viewerSplit: Double = 0.667
    @AppStorage(SettingsKey.subjectCombineAny) private var subjectCombineAny: Bool = false
    @AppStorage(SettingsKey.readFilterDefault) private var readFilterDefault: ReadFilter = .all
    @AppStorage(SettingsKey.warnNearDuplicate) private var warnNearDuplicate: Bool = true
    @AppStorage("ar.listFontSize") private var listFontSize: Double = 13
    @ObservedObject private var excludedFolders = ExcludedFoldersStore.shared

    var body: some View {
        Form {
            Section("Copying links") {
                Picker("Link format", selection: $linkFormat) {
                    ForEach(LinkFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Stepper(value: $linkNewlines, in: 0...5) {
                    Text("Blank lines between links: \(linkNewlines)")
                }
            }
            Section("Copying text") {
                Toggle("Collapse single line breaks into spaces", isOn: $copyCollapse)
                Toggle("Blank line = paragraph break", isOn: $copyParagraph)
                Toggle("Rejoin hyphenated line-splits (wel-/fare → welfare)", isOn: $copyDehyphenate)
            }
            Section("Document viewer") {
                VStack(alignment: .leading) {
                    Text("Default split: image \(Int(viewerSplit * 100))% / text \(Int((1 - viewerSplit) * 100))%")
                    Slider(value: $viewerSplit, in: 0.2...0.8)
                }
            }
            Section("Navigation defaults") {
                Picker("Default read-state filter", selection: $readFilterDefault) {
                    Text("All").tag(ReadFilter.all)
                    Text("Unread").tag(ReadFilter.unread)
                    Text("Read").tag(ReadFilter.read)
                    Text("No read-state").tag(ReadFilter.noReadState)
                }
                Toggle("Combine multiple subject filters with ANY (off = ALL)", isOn: $subjectCombineAny)
            }
            Section("File list") {
                VStack(alignment: .leading) {
                    Text("List text size: \(Int(listFontSize)) pt (smaller = more compact rows)")
                    Slider(value: $listFontSize, in: 10...20, step: 1)
                }
            }
            Section("Tag editing") {
                Toggle("Warn when a new subject differs only by case from an existing one", isOn: $warnNearDuplicate)
            }
            Section("Excluded folders") {
                Text("Files in these folders are hidden from the library and not indexed for search.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if excludedFolders.excludedRelativePaths.isEmpty {
                    Text("No folders excluded.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(excludedFolders.excludedRelativePaths, id: \.self) { rel in
                        HStack {
                            Image(systemName: "folder.badge.minus")
                                .foregroundStyle(.secondary)
                            Text(rel)
                            Spacer()
                            Button(role: .destructive) {
                                excludedFolders.remove(rel)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                Button("Add Folder\u{2026}") { addExcludedFolder() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 620)
    }

    private func addExcludedFolder() {
        guard let rootURL = resolveArchiveRoot() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        panel.prompt = "Exclude"
        panel.message = "Choose a subfolder to exclude from the library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rootPath = rootURL.path.hasSuffix("/") ? String(rootURL.path.dropLast()) : rootURL.path
        let chosen = url.path
        // Must be a descendant of root.
        guard chosen.hasPrefix(rootPath + "/") else { return }
        let relative = String(chosen.dropFirst(rootPath.count + 1))
        excludedFolders.add(relative)
    }

    /// Resolve the archive root from the persisted bookmark (same key as RootFolderStore).
    private func resolveArchiveRoot() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: "archiveRootBookmark") else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                        relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
