import SwiftUI
import AppKit

// Discoverable main-window keyboard shortcuts, exposed as a menu-bar `CommandMenu` so they show their
// key equivalents in the menu (⌘R, ⌘⌥P) and route through AppKit's menu system rather than hijacking
// text input. Chosen combos are free: the app only removes ⌘N (`.newItem`); ⌘, is the system Settings
// shortcut; every other existing `.keyboardShortcut` is scoped to a modal sheet (Return/Esc/⌘Return).
//
// The menu items only POST a request; the real work runs in MainActor view observers (`OCRView` for
// Start — reusing its exact enable guard; `ContentView` for Cycle provider). Both observers stand down
// while a text field is being edited (`TextEditingGuard`), so a shortcut never steals a keystroke from
// typing and Start can never begin a run the button itself wouldn't allow.

extension Notification.Name {
    /// Posted from the menu when the user requests "Start processing" (⌘R). `OCRView` runs its normal
    /// Start action iff it is currently allowed (files loaded, key present, output set, not busy).
    static let startProcessingRequested = Notification.Name("StartProcessingRequested")
    /// Posted from the menu to cycle the LLM provider (⌘⌥P). Handled in `ContentView`.
    static let cycleProviderRequested = Notification.Name("CycleProviderRequested")
    /// Posted after a processing profile is applied so views holding derived `@State` (selected model,
    /// API-key fields) re-sync from the freshly-written UserDefaults values.
    static let processingProfileApplied = Notification.Name("ProcessingProfileApplied")
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

enum ProviderCycler {
    /// Advance `selectedProvider` to the next provider (Anthropic → Gemini → Mistral → wrap), writing the
    /// shared `@AppStorage` key so the main window and Settings both update. `OCRView`/`SettingsView`
    /// observe the change and re-point the selected model + API-key field for the new provider.
    @MainActor static func advance() {
        let d = UserDefaults.standard
        let current = LLMProvider(rawValue: d.string(forKey: DefaultsKeys.selectedProvider) ?? "") ?? .gemini
        let all = LLMProvider.allCases
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

            Button("Cycle Provider") {
                NotificationCenter.default.post(name: .cycleProviderRequested, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}
