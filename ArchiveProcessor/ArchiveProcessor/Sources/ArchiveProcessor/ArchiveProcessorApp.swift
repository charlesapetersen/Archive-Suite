import SwiftUI

@main
struct ArchiveProcessorApp: App {
    init() {
        OCRProcessor.requestNotificationPermission()
        // One-time: adopt the new default rotation mode (llmSingle — overlaps OCR, ~same accuracy)
        // for users still sitting on the old llmMajority default.
        let d = UserDefaults.standard
        if !d.bool(forKey: DefaultsKeys.rotationDefaultMigratedV1) {
            if d.string(forKey: DefaultsKeys.rotationModeRaw) == RotationMode.llmMajority.rawValue {
                d.set(RotationMode.llmSingle.rawValue, forKey: DefaultsKeys.rotationModeRaw)
            }
            d.set(true, forKey: DefaultsKeys.rotationDefaultMigratedV1)
        }
        // The previous-page text-context slider was removed (it forced slow sequential OCR and was
        // redundant with "send previous page image"). Zero any persisted value so OCR runs parallel.
        if !d.bool(forKey: DefaultsKeys.contextRemovedMigratedV1) {
            d.set(0.0, forKey: DefaultsKeys.contextCharCount)
            d.set(true, forKey: DefaultsKeys.contextRemovedMigratedV1)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
        }
    }
}
