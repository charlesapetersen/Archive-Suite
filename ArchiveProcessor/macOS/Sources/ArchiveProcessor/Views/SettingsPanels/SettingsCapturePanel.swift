import SwiftUI
import ArchiveCore

/// Settings › Capture (W47.settings-panels): live processing, reading box and folder labels, the Drive relay, and how
/// the phone takes its photos.
struct SettingsCapturePanel: View {
    @AppStorage(DefaultsKeys.readContainerLabels) private var readContainerLabels: Bool = true
    @AppStorage(DefaultsKeys.liveProcessingMode) private var liveProcessingMode: String = LiveProcessingMode.stage.rawValue
    @AppStorage(DefaultsKeys.driveClientId) private var driveClientId: String = ""
    @ObservedObject private var gemma = ManagedGemma.shared
    @State private var confirmGemmaDownload = false
    @State private var driveClientSecret = ""
    @State private var driveSignedIn = false
    @State private var signingIn = false
    @State private var driveStatus = ""
    @State private var driveAuth: DriveAuth? = nil   // retains the auth object across the async loopback flow

    var body: some View {
        Form {
            liveCaptureSection
            Section {
                SettingsStageCards(rules: ["capture"])
            }
        }
        .formStyle(.grouped)
        .onChange(of: readContainerLabels) { _, enabled in
            if !enabled { gemma.stop() }
        }
        .confirmationDialog(gemma.installed ? "Retry Gemma setup?" : "Download Gemma 3 12B?",
                            isPresented: $confirmGemmaDownload, titleVisibility: .visible) {
            Button(gemma.installed ? "Retry Setup" : "Download") { gemma.download() }
        } message: {
            Text(ManagedGemma.sizeNote)
        }
    }

    @ViewBuilder private var liveCaptureSection: some View {
        Section {
            Picker(selection: $liveProcessingMode) {
                Text("Stage for later").tag(LiveProcessingMode.stage.rawValue)
                Text("Process live").tag(LiveProcessingMode.live.rawValue)
            } label: {
                HStack {
                    Text("When capturing")
                    HelpButton(text: "Stage for later: captures collect in Live Capture; send them to Process Files for a normal batch run.\n\nProcess live: each captured segment is OCR'd, tagged, and turned into a PDF as you shoot (using the settings here); confirm collection names at the end.")
                }
            }
            Toggle(isOn: $readContainerLabels) {
                HStack {
                    Text("Read box and folder labels")
                    HelpButton(text: "When processing live, each Box or Folder photo is read into repository, collection, accession, series, box and folder, shown on a card for you to correct, and saved beside the collection's files (in its hidden .archivesuite folder) when you finish. Process Files reads its box and folder labels the same way and saves them as proposals, to confirm in Archive Reader. Box and folder numbers come from the photo's text; with the AI gateway on, titles, collection number, date and accession come from GPT 5.6 Luna on the gateway, one short call per label photo. Without it (or with a local model as the gateway), Gemma 3 12B on this Mac can propose repository, collection title, collection number and date. The app uses an existing local server that lists Gemma or the reader you download here.")
                }
            }

            if readContainerLabels {
                VStack(alignment: .leading, spacing: 6) {
                    if gemma.installed, gemma.runtimeStatus == nil {
                        Label("Gemma 3 12B is installed on this Mac", systemImage: "checkmark.circle")
                    } else if ManagedGemma.supported {
                        if let status = gemma.runtimeStatus { Text(status) }
                        else { Text(ManagedGemma.sizeNote) }
                        if let status = gemma.installStatus { Text(status) }
                        if gemma.installing {
                            Button("Pause Download") { gemma.pauseDownload() }
                        } else {
                            HStack {
                                Button(gemma.installed ? "Retry Gemma Setup…" : "Download Gemma 3 12B…") { confirmGemmaDownload = true }
                                    .accessibilityIdentifier("ap.gemma.settingsDownload")
                                Link("Gemma terms", destination: ManagedGemmaBanner.termsURL)
                            }
                        }
                    } else {
                        Text(ManagedGemma.requirements)
                    }
                }
                .font(.caption)
            }
            // The Mac ALWAYS listens on the LAN and ADDITIONALLY relays through Google Drive whenever it's
            // signed in — there is no transport picker to misconfigure (A5). Sign-in below is pure
            // enablement: the pairing QR then carries a relay code too, so a phone can pick Wired, Wi-Fi, or
            // Cloud from the SAME scan. Leave the Drive fields blank to run LAN/USB only.
            VStack(alignment: .leading, spacing: 8) {
                Text("Cloud relay (Google Drive) — optional")
                    .font(.caption).fontWeight(.medium)
                HStack {
                    Text("Google client ID").font(.caption)
                    HelpButton(text: "The OAuth Desktop-app client ID for the Drive relay (from your Google Cloud project, ending in .apps.googleusercontent.com). Stored in app settings; the matching secret goes in the Keychain.")
                    Spacer()
                }
                TextField("Google client ID", text: $driveClientId, prompt: Text("…apps.googleusercontent.com"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Client secret").font(.caption)
                    HelpButton(text: "The OAuth Desktop-app client secret (GOCSPX-…). Saved to the macOS Keychain, never written to disk or settings.")
                    Spacer()
                }
                SecureField("Client secret", text: $driveClientSecret, prompt: Text("GOCSPX-…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: driveClientSecret) { _, v in _ = KeychainHelper.save(account: "DriveClientSecret", password: v) }
                HStack(spacing: 10) {
                    Button(driveSignedIn ? "Re-sign in" : "Sign in to Google Drive") { signInToDrive() }
                        .disabled(driveClientId.isEmpty || driveClientSecret.isEmpty || signingIn)
                    if signingIn { ProgressView().controlSize(.small) }
                    if driveSignedIn {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                        Button("Sign out") { signOutDrive() }.font(.caption)
                    }
                    Spacer()
                }
                if !driveStatus.isEmpty {
                    Text(driveStatus).font(.caption).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Sign in with the same Google account on the Mac and the phone. Then Start in Live Capture — the Mac watches Drive automatically while a session is active, and the phone can pick Cloud when it scans the QR.")
                    .font(.caption2).foregroundStyle(.primary)
            }
            .onAppear { loadDriveState() }
            .settingsLevel(.driveRelay)
        } header: {
            Text("Live Capture")
        }
    }

    private func loadDriveState() {
        driveClientSecret = KeychainHelper.load(account: "DriveClientSecret") ?? ""
        driveSignedIn = KeychainHelper.load(account: "DriveRefreshToken") != nil
    }

    /// Owner-gated interactive Google sign-in for the Drive relay: opens the browser + loopback flow, then
    /// stores the refresh token in the Keychain (via `DriveAuth`). The secret is persisted first so the
    /// running `CaptureSession.cloudRelay` reads the same credentials.
    private func signInToDrive() {
        _ = KeychainHelper.save(account: "DriveClientSecret", password: driveClientSecret)
        signingIn = true
        driveStatus = "Opening Google sign-in in your browser — approve access, then return here."
        let auth = DriveAuth(clientId: driveClientId.trimmingCharacters(in: .whitespaces), clientSecret: driveClientSecret)
        driveAuth = auth   // signIn captures self weakly; hold a strong ref until the redirect completes
        auth.signIn { result in
            // Reduce to a Sendable String? BEFORE the actor hop (the Error itself isn't Sendable).
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
