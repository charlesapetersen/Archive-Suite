import SwiftUI
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
            MessageJourneyFixture.resetKeyWizardIfRequested()
            ProcessorUITestConfiguration.installScratchCollectionSettings()   // the range view's click check
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
        }

        Settings {
            SettingsView()
        }
    }
}
