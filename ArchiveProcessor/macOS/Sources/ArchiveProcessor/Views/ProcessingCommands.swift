import SwiftUI
import AppKit

// Discoverable main-window keyboard shortcuts, exposed as a menu-bar `CommandMenu` so they show their
// key equivalents in the menu (⌘R, ⌘⌥P) and route through AppKit's menu system rather than hijacking
// text input. Chosen combos are free: the app replaces File ▸ New (`.newItem`) with Add Files… (⌘O) and
// Choose Output Folder… (⇧⌘O, the suite's "choose folder" key: Choose Archive Folder… in the Reader and
// Notes; W40.fix-suite-shortcuts); ⌘, is the system Settings shortcut; Stop Processing is ⌘., the Mac's
// Cancel; every other existing `.keyboardShortcut` is scoped to a modal sheet (Return/Esc/⌘Return).
//
// The menu items only POST a request; the real work runs in MainActor view observers (`OCRView` for
// Start, Stop and the two panels — each reusing its button's exact guard; `ContentView` for Cycle
// provider). With another mode in front (Live Capture, Tools) no `OCRView` is listening, so they do
// nothing, as the buttons are not there either. Every observer stands down
// while a text field is being edited (`TextEditingGuard`), so a shortcut never steals a keystroke from
// typing and Start can never begin a run the button itself wouldn't allow.

extension Notification.Name {
    /// Posted from the menu when the user requests "Start processing" (⌘R). `OCRView` runs its normal
    /// Start action iff it is currently allowed (files loaded, key present, output set, not busy).
    static let startProcessingRequested = Notification.Name("StartProcessingRequested")
    /// Posted from the menu to cycle the LLM provider (⌘⌥P). Handled in `ContentView`.
    static let cycleProviderRequested = Notification.Name("CycleProviderRequested")
    /// Posted from the menu to stop the run or the review (⌘.), as the Cancel button does. Handled in `OCRView`.
    static let stopProcessingRequested = Notification.Name("StopProcessingRequested")
    /// Posted from File ▸ Add Files… (⌘O); `OCRView` opens its file panel when its Add Files… button would.
    static let addFilesRequested = Notification.Name("AddFilesRequested")
    /// Posted from File ▸ Choose Output Folder… (⇧⌘O); `OCRView` opens its output-folder panel.
    static let chooseOutputFolderRequested = Notification.Name("ChooseOutputFolderRequested")
    /// Posted from Processing ▸ Improve OCR… (⇧⌘I); `OCRView` opens the Improve OCR dialog for its PDFs (W44).
    static let improveOCRRequested = Notification.Name("ImproveOCRRequested")
    /// Posted by `ContentView.onOpenURL` with an `archiveprocessor://improve-ocr` link from the Reader (W44); `OCRView`
    /// resolves it (`ImproveOCRHandoff`) and opens the dialog, which only ever opens: nothing runs from a link.
    static let improveOCRHandoff = Notification.Name("ImproveOCRHandoff")
    /// Posted from Processing ▸ Improve OCR History…; `OCRView` shows what Improve OCR has kept (W44).
    static let improveOCRHistoryRequested = Notification.Name("ImproveOCRHistoryRequested")
    /// Posted from Processing ▸ Improve OCR on Flagged Files…; `OCRView` asks for a folder and opens the dialog for the
    /// PDFs in it tagged OCR Poor (W44).
    static let improveOCRFlaggedRequested = Notification.Name("ImproveOCRFlaggedRequested")
}

/// Whether a text field / field editor currently holds keyboard focus. Global shortcuts stand down when
/// this is true so they never steal a keystroke from the user while they are typing into a field.
enum TextEditingGuard {
    @MainActor static var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isFieldEditor || textView.isEditable }
        return responder is NSTextField
    }
}

/// Whether the window in front has a sheet or an alert up. The File menu's panels and Stop Processing stand down
/// then: an answer the sheet asks for (the plan check's Go on / Stop here) is never taken from under it by ⌘. .
enum SheetGuard {
    @MainActor static var sheetIsUp: Bool {
        NSApp.modalWindow != nil || NSApp.keyWindow?.attachedSheet != nil || NSApp.keyWindow?.isSheet == true
    }
}

enum ProviderCycler {
    /// Advance `selectedProvider` to the next provider (Anthropic → Gemini → Mistral → wrap), writing the
    /// shared `@AppStorage` key so the main window and Settings both update. `OCRView`/`SettingsView`
    /// observe the change and re-point the selected model + API-key field for the new provider.
    @MainActor static func advance() {
        let d = UserDefaults.standard
        let current = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        // Vision is a local backend toggled in Settings, not an API provider with a selectable key/model.
        // Cycling returns to the normal provider picker instead of appearing to change an inactive value.
        if d.bool(forKey: DefaultsKeys.useAppleVision) {
            d.set(false, forKey: DefaultsKeys.useAppleVision)
            return
        }
        let all = LLMProvider.allCases.filter { $0 != .appleVision }
        guard let idx = all.firstIndex(of: current) else { return }
        d.set(all[(idx + 1) % all.count].rawValue, forKey: DefaultsKeys.selectedProvider)
    }
}

struct ProcessingCommands: Commands {
    var body: some Commands {
        CommandMenu("Processing") {
            Button("Start Processing") {
                NotificationCenter.default.post(name: .startProcessingRequested, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Button("Stop Processing") {
                NotificationCenter.default.post(name: .stopProcessingRequested, object: nil)
            }
            .keyboardShortcut(".", modifiers: .command)

            Button("Cycle Provider") {
                NotificationCenter.default.post(name: .cycleProviderRequested, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])

            Divider()
            Button("Improve OCR\u{2026}") {
                NotificationCenter.default.post(name: .improveOCRRequested, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Improve OCR on Flagged Files\u{2026}") {
                NotificationCenter.default.post(name: .improveOCRFlaggedRequested, object: nil)
            }
            Button("Improve OCR History\u{2026}") {
                NotificationCenter.default.post(name: .improveOCRHistoryRequested, object: nil)
            }
        }
    }
}

/// File menu: in place of New, which the Processor has no use for.
struct ProcessorFileCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Files\u{2026}") {
                NotificationCenter.default.post(name: .addFilesRequested, object: nil)
            }
            .keyboardShortcut("o", modifiers: .command)
            Button("Choose Output Folder\u{2026}") {
                NotificationCenter.default.post(name: .chooseOutputFolderRequested, object: nil)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
