import SwiftUI
import ArchiveCore

/// Settings › Capture (W49.proc-settings-redesign-core, §5.3): Live Capture's mode, reading box and folder labels, and the
/// optional Google Drive relay behind a disclosure. The label reader's download is in Settings › Accounts.
struct SettingsCaptureTab: View {
    @AppStorage(DefaultsKeys.readContainerLabels) private var readContainerLabels = true
    @AppStorage(DefaultsKeys.liveProcessingMode) private var liveProcessingMode = LiveProcessingMode.stage.rawValue
    @AppStorage(DefaultsKeys.driveClientId) private var driveClientId = ""
    @ObservedObject private var gemma = ManagedGemma.shared
    @State private var driveClientSecret = ""
    @State private var driveSignedIn = false
    @State private var signingIn = false
    @State private var driveStatus = ""
    @State private var driveAuth: DriveAuth? = nil   // retains the auth object across the async loopback flow
    @State private var relayOpen = false

    var body: some View {
        Form {
            Section("Live Capture") {
                Picker(selection: $liveProcessingMode) {
                    Text("Stage for later").tag(LiveProcessingMode.stage.rawValue)
                    Text("Process live").tag(LiveProcessingMode.live.rawValue)
                } label: {
                    HelpLabel("When capturing", help: "Stage for later: captures collect in Live Capture; send them to Process Files for a normal batch run.\n\nProcess live: each captured segment is read, tagged and turned into a PDF as you shoot, with the Processing settings; you confirm collection names at the end.")
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("ap.settings.liveProcessingMode")
                Toggle(isOn: $readContainerLabels) {
                    HelpLabel("Read box and folder labels", help: "Each Box or Folder photo is read into repository, collection, accession, series, box and folder, shown on a card for you to correct, and saved with the collection when you finish. Box and folder numbers come from the photo's text; with the AI gateway on, titles, collection number, date and accession come from GPT 5.6 Luna on the gateway, one short call per label photo. Without it, Gemma 3 12B on this Mac can propose them.")
                }
                .accessibilityIdentifier("ap.settings.readContainerLabels")
                if readContainerLabels {
                    Text(gemma.installed
                         ? "Label reader: Gemma 3 12B is installed on this Mac (manage it in Settings › Accounts)."
                         : "Label reader: Gemma 3 12B is not installed; download it in Settings › Accounts › Local models.")
                        .font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ap.settings.labelReader")
                }
            }
            Section {
                LabeledContent("Google Drive relay (optional)") {
                    HStack {
                        Text(driveSignedIn ? "Signed in" : "Not connected").foregroundStyle(.primary)
                        Button(relayOpen ? "Hide" : "Configure…") { relayOpen.toggle() }
                            .accessibilityIdentifier("ap.settings.driveRelay")
                    }
                }
                if relayOpen { relayFields }
                Text("Wired and Wi-Fi capture work without Google Drive.")
                    .font(.caption2).foregroundStyle(.primary)
            } header: { Text("Cloud relay") }
        }
        .formStyle(.grouped)
        .onChange(of: readContainerLabels) { _, enabled in
            if !enabled { gemma.stop() }
        }
        .onAppear {
            driveClientSecret = KeychainHelper.load(account: DriveAuth.clientSecretAccount) ?? ""
            driveSignedIn = KeychainHelper.load(account: DriveAuth.refreshTokenAccount) != nil
            relayOpen = driveSignedIn || !driveClientId.isEmpty
        }
    }

    // The Mac always listens on the LAN and also relays through Google Drive whenever it is signed in: there is no
    // transport picker to misconfigure (A5). The pairing QR then carries a relay code, so a phone can pick Wired, Wi-Fi
    // or Cloud from the same scan.
    @ViewBuilder private var relayFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsField("Google client ID") {
                TextField("Google client ID", text: $driveClientId, prompt: Text("…apps.googleusercontent.com"))
            }
            .help("The OAuth Desktop-app client ID for the Drive relay, from your Google Cloud project. Stored in app settings; the matching secret goes in the Keychain.")
            SettingsField("Client secret") {
                SecureField("Client secret", text: $driveClientSecret, prompt: Text("GOCSPX-…"))
                    .onChange(of: driveClientSecret) { _, v in _ = KeychainHelper.save(account: DriveAuth.clientSecretAccount, password: v) }
            }
            .help("Saved to the macOS Keychain, never written to disk or settings.")
            HStack(spacing: 10) {
                Button(driveSignedIn ? "Re-sign in" : "Sign in to Google Drive") { signInToDrive() }
                    .disabled(driveClientId.isEmpty || driveClientSecret.isEmpty || signingIn)
                if signingIn { ProgressView().controlSize(.small) }
                if driveSignedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill").font(.caption)
                    Button("Sign out") { signOutDrive() }.font(.caption)
                }
                Spacer()
            }
            if !driveStatus.isEmpty {
                Text(driveStatus).font(.caption).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Sign in with the same Google account on the Mac and the phone. The Mac watches Drive while a Live Capture session is active, and the phone can pick Cloud when it scans the QR.")
                .font(.caption2).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Interactive Google sign-in for the Drive relay: opens the browser and loopback flow, then stores the refresh
    /// token in the Keychain (`DriveAuth`). The secret is saved first so a running session reads the same credentials.
    private func signInToDrive() {
        _ = KeychainHelper.save(account: DriveAuth.clientSecretAccount, password: driveClientSecret)
        signingIn = true
        driveStatus = "Opening Google sign-in in your browser — approve access, then return here."
        let auth = DriveAuth(clientId: driveClientId.trimmingCharacters(in: .whitespaces), clientSecret: driveClientSecret)
        driveAuth = auth   // signIn captures self weakly; hold a strong ref until the redirect completes
        auth.signIn { result in
            // Reduce to a Sendable String? before the actor hop (the Error itself isn't Sendable).
            let errorMessage: String? = { if case .failure(let e) = result { return e.localizedDescription }; return nil }()
            Task { @MainActor in
                signingIn = false
                if let errorMessage {
                    driveSignedIn = false
                    driveStatus = "Sign-in failed: \(errorMessage)"
                } else {
                    driveSignedIn = true
                    driveStatus = "Signed in to Google Drive."
                }
            }
        }
    }

    private func signOutDrive() {
        DriveAuth(clientId: driveClientId, clientSecret: driveClientSecret).signOut()
        driveSignedIn = false
        driveStatus = "Signed out."
    }
}
