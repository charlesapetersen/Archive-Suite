import SwiftUI
import ArchiveCoreUI
import ArchiveCore

@main
struct ArchiveProcessorApp: App {
    @NSApplicationDelegateAdaptor(ProcessorAppDelegate.self) private var appDelegate
    // The Backup Folder has one active capture roster, even with multiple Process Files windows.
    @StateObject private var capture = CaptureSession()

    init() {
        var appearanceForced = false
#if DEBUG
        // This happens before any view reads @AppStorage. The UI suite supplies disposable paths and
        // ARCHIVEPROC_HEADLESS=1, so it never opens a Keychain item or a remembered real folder.
        ProcessorUITestConfiguration.installScratchDefaults()
        ProcessorUITestConfiguration.ignoreSavedWindowStateIfHeadless()
        MainActor.assumeIsolated {
            appearanceForced = UITestAppearance.applyIfRequested()   // layout guard light/dark (W40.e9)
            TransientRecorder.startIfRequested()  // the transient-state check (W40.e13)
            do {
                try PaidBatchUITestFixture.seedIfRequested()
            } catch {
                preconditionFailure("Could not seed the scratch paid batch: \(error)")
            }
            MoneyJourneyFixture.configureIfRequested()
            ProcessorUITestConfiguration.clearKeyChips()   // no chip left over from an earlier suite
            ProcessorUITestConfiguration.clearAdvancedSettingsIfRequested()
            MessageJourneyFixture.resetKeyWizardIfRequested()
            ProcessorUITestConfiguration.installScratchCollectionSettings()   // the range view's click check
            ProcessorUITestConfiguration.installScratchTagLists()   // the Tags window's check (W40.tag-window-processor)
        }
#endif
        // The Appearance setting (W48.appearance-processor), before the first window; a UI test's forced mode wins.
        if !appearanceForced { MainActor.assumeIsolated { AppAppearance.follow() } }
        OCRProcessor.requestNotificationPermission()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(capture: capture)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            ProcessorFileCommands()
            ProcessingCommands()
            DiagnosticsCommands()
        }

        // Window ▸ Tags (W40.tag-window-processor): the shared Tags window over the Processor's two lists.
        Window("Tags", id: ProcessorTagsWindow.id) {
            ProcessorTagsWindow()
        }
        .defaultSize(width: 560, height: 520)

        Settings {
            SettingsView()
        }
    }
}
