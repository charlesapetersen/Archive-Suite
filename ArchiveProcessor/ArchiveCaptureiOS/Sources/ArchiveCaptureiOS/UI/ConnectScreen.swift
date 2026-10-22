import SwiftUI

/// Pairing screen: the operator chooses Wi-Fi or Cloud (Android's ConnectScreen, less Wired: an iPhone has no
/// adb tunnel), then scans the Mac's Live Capture QR code or types the details. Wi-Fi dials the QR's host;
/// Cloud uses its relay code through Google Drive, with no LAN probe. Driven by `vm.connectPhase` so it names
/// what it's doing the instant the QR decodes and, on failure, names the cause + the fix with a clean
/// "Try again" — never a dead spinner or a wrong "same Wi-Fi" message.
struct ConnectScreen: View {
    @ObservedObject var vm: CaptureViewModel
    enum Mode: String, CaseIterable { case wifi = "Wi-Fi", cloud = "Cloud" }
    @State private var mode: Mode = .wifi
    @State private var showScanner = false
    @State private var showManual = false
    @State private var host = ""
    @State private var port = ""
    @State private var token = ""
    @State private var relayToken = ""
    @State private var manualError: String?

    private var isConnecting: Bool {
        switch vm.connectPhase {
        case .connecting, .signingIn: return true
        default: return false
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Connect to your Mac").font(.title2).bold()

            Picker("How is this phone connected?", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal)
            .disabled(isConnecting)
            .onChange(of: mode) { _, _ in
                vm.resetConnectPhase()
                manualError = nil
                showManual = false
            }

            switch mode {
            case .wifi: wifiSection
            case .cloud: cloudSection
            }

            Spacer()
        }
        .sheet(isPresented: $showScanner) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { payload in
                    showScanner = false
                    let cloud = mode == .cloud
                    Task {
                        if cloud { await vm.connectCloudFromQR(payload) } else { await vm.connectFromQR(payload) }
                    }
                }
                .ignoresSafeArea()
                Button { showScanner = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white)
                }
                .padding()
            }
        }
    }

    private var scanButton: some View {
        Button { presentScanner() } label: {
            Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
        .disabled(isConnecting)
    }

    // MARK: - Wi-Fi

    @ViewBuilder private var wifiSection: some View {
        Text("Open the Live Capture tab in the Archive Processor Mac app and scan the QR code it shows. Both devices must be on the same Wi-Fi.")
            .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)

        scanButton

        phaseView

        DisclosureGroup("Enter manually", isExpanded: $showManual) {
                VStack(spacing: 8) {
                    TextField("Host (e.g. 192.168.1.5)", text: $host)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $port).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                    TextField("Token", text: $token)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Connect") { manualConnect() }
                        .buttonStyle(.bordered)
                        .disabled(host.isEmpty || port.isEmpty || token.isEmpty || isConnecting)
                    if let manualError {
                        Text(manualError).foregroundStyle(.red).font(.caption)
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal)
    }

    /// Immediate feedback + cause-named failures, all from the explicit connect phase.
    @ViewBuilder private var phaseView: some View {
        switch vm.connectPhase {
        case .idle:
            EmptyView()
        case .connecting(let h, let p):
            ProgressView("Found pairing code — connecting to \(h):\(p)…")
                .multilineTextAlignment(.center).padding(.horizontal)
        case .unreachable(let h, let p):
            failure("""
                Can't reach the Mac at \(h):\(p). This Wi-Fi may block device-to-device connections \
                (common on public/guest/hotel networks). USB isn't available on iPhone, so use a personal \
                hotspot (join both devices to it), or check the Mac's Live Capture tab is listening.

                If you tapped Don't Allow on the local-network prompt, enable it in \
                Settings ▸ Archive Capture ▸ Local Network. Or choose Cloud above to send through Google Drive.
                """)
        case .refused(let h, let p):
            failure("Reached the network but nothing is listening at \(h):\(p) — is Live Capture started on the Mac?")
        case .unauthorized:
            failure("Pairing code rejected — re-scan the QR (it may be stale).")
        case .badQR:
            failure("That isn't an Archive Processor pairing code.")
        case .signingIn:
            ProgressView("Signing in to Google…").padding(.horizontal)
        case .noRelay:
            failure("That QR has no cloud relay code — sign the Mac into Google Drive (Settings ▸ Live Capture), then rescan.")
        case .cloudOnlyQR:
            failure("That's a Cloud pairing code — choose Cloud above and scan it there.")
        case .cloudFailed(let message):
            failure(message)
        }
    }

    /// A cause message plus a "Try again" that re-presents the scanner — so a failure is never a dead end.
    @ViewBuilder private func failure(_ message: String) -> some View {
        VStack(spacing: 10) {
            Text(message).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center)
            Button { presentScanner() } label: { Label("Try again", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal)
    }

    private func presentScanner() {
        vm.resetConnectPhase()
        manualError = nil
        showScanner = true
    }

    private func manualConnect() {
        manualError = nil
        guard let p = Int(port), (1...65535).contains(p) else {
            manualError = "Port must be a number between 1 and 65535."
            return
        }
        Task {
            await vm.connect(host: host.trimmingCharacters(in: .whitespaces), port: p,
                             token: token.trimmingCharacters(in: .whitespaces))
        }
    }

    // MARK: - Cloud (Google Drive relay)

    /// Cloud pairing: scan the Mac's QR (it carries the relay code when the Mac is signed into Drive) or type the
    /// relay token, then sign in to the SAME Google account the Mac uses. Uploads then go through Drive, so this
    /// works on networks that block device-to-device connections.
    @ViewBuilder private var cloudSection: some View {
        if !DriveAuth.isConfigured {
            // No OAuth client in this build (Config/DriveLocal.xcconfig): a sign-in could only draw Google's
            // invalid_client page, so say why the cloud relay is unavailable instead.
            Label("Google Drive relay not configured in this build", systemImage: "cloud.slash")
                .foregroundStyle(.secondary).font(.callout)
            Text("Wi-Fi capture works as normal. The cloud relay needs an iOS OAuth client — see README-oauth.md.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .padding(.horizontal)
        } else {
            Text("Sign the Mac into Google Drive (Settings ▸ Live Capture) and Start in Live Capture, then scan the QR it shows — the same code works for Cloud. You'll sign in to the same Google account the Mac uses.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)

            scanButton

            phaseView

            DisclosureGroup("Enter relay token", isExpanded: $showManual) {
                VStack(spacing: 8) {
                    TextField("Relay token", text: $relayToken)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Sign in & connect") {
                        let t = relayToken
                        Task { await vm.connectCloud(relayToken: t) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(relayToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal)

            DriveSignInStatus(auth: vm.driveAuth).disabled(isConnecting)
        }
    }
}

/// Signed-in line + sign-out. Its own view so it observes `DriveAuth` directly: `ConnectScreen` observes only the
/// view model, which doesn't republish a sign-out.
private struct DriveSignInStatus: View {
    @ObservedObject var auth: DriveAuth

    var body: some View {
        if auth.isSignedIn {
            Label("Signed in to Google Drive", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
            Button("Sign out of Google Drive", role: .destructive) { auth.signOut() }
                .font(.caption)
        }
    }
}
