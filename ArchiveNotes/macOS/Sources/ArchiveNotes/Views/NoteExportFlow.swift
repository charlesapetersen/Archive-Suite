import AppKit

/// File ▸ Export… and File ▸ Print… (W49.notes-export-print): the panels and alerts around `NoteExportWriter` and
/// `NoteExportRenderer`. Both first save every open editor, so what leaves the app is what the user sees.
@MainActor
enum NoteExportFlow {

    /// Ask for a folder and a format, then write `ids` there. A UI test names the folder and the format in its
    /// launch arguments instead (`-ANUITestExportPath`, `-ANUITestExportFormat`), since the folder panel runs
    /// out of process.
    static func export(_ ids: [UUID], model: NotesModel, registry: EditorFlushRegistry, archiveRoots: [URL]) async {
        guard !ids.isEmpty else { NSSound.beep(); return }
        let window = NSApp.keyWindow
        _ = await registry.flushAll()
        let (sources, failed) = await model.exportSources(for: ids)
        guard !sources.isEmpty else {
            alert("The selected items could not be read, so nothing was exported.", detail: failed.joined(separator: ", "),
                  window: window)
            return
        }
        guard let (folder, format) = await chooseDestination(count: sources.count, window: window) else { return }
        UserDefaults.standard.set(format.rawValue, forKey: NoteExportFormat.defaultsKey)
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        do {
            let written = try NoteExportWriter.export(sources, as: format, into: folder,
                                                      storeRoot: model.storeRootURL, archiveRoots: archiveRoots)
            let noun = written.count == 1 ? "item" : "items"
            model.statusMessage = "Exported \(written.count) \(noun) as \(format.title) to “\(folder.lastPathComponent)”."
            if !failed.isEmpty {
                alert("Some items could not be read and were not exported.", detail: failed.joined(separator: ", "),
                      window: window)
            }
        } catch {
            alert("The export did not finish.", detail: error.localizedDescription, window: window)
        }
    }

    /// Print `ids` as one document, each item starting on a new page.
    static func print(_ ids: [UUID], model: NotesModel, registry: EditorFlushRegistry) async {
        guard !ids.isEmpty else { NSSound.beep(); return }
        let window = NSApp.keyWindow
        _ = await registry.flushAll()
        let (sources, failed) = await model.exportSources(for: ids)
        guard !sources.isEmpty else {
            alert("The selected items could not be read, so nothing was printed.", detail: failed.joined(separator: ", "),
                  window: window)
            return
        }
        let info = NoteExportRenderer.printInfo()
        let width = NoteExportRenderer.printableWidth(info)
        let view = NoteExportRenderer.printableView(
            NoteExportRenderer.attributed(sources, embedImages: true, imageWidth: width), width: width)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = sources.count == 1 ? sources[0].displayTitle : "\(sources.count) Notes"
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    private static func chooseDestination(count: Int, window: NSWindow?) async -> (URL, NoteExportFormat)? {
#if DEBUG
        if let path = UserDefaults.standard.string(forKey: "ANUITestExportPath"), !path.isEmpty {
            let format = UserDefaults.standard.string(forKey: "ANUITestExportFormat")
                .flatMap(NoteExportFormat.init(rawValue:)) ?? NoteExportFormat.remembered()
            return (URL(fileURLWithPath: path, isDirectory: true), format)
        }
#endif
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.title = "Export"
        panel.message = count == 1
            ? "Choose a folder for the exported item. Nothing already in the folder is replaced."
            : "Choose a folder for the \(count) exported items, one file each. Nothing already in the folder is replaced."
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in NoteExportFormat.allCases {
            popup.addItem(withTitle: format.title)
            popup.lastItem?.representedObject = format.rawValue
        }
        popup.selectItem(at: NoteExportFormat.allCases.firstIndex(of: NoteExportFormat.remembered()) ?? 0)
        popup.setAccessibilityIdentifier("an.export.format")
        let label = NSTextField(labelWithString: "Format:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        row.frame = NSRect(origin: .zero, size: row.fittingSize)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true

        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return nil }
        let format = (popup.selectedItem?.representedObject as? String).flatMap(NoteExportFormat.init(rawValue:))
            ?? .markdown
        return (url, format)
    }

    private static func alert(_ message: String, detail: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
