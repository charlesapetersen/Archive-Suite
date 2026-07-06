import SwiftUI

/// Pairing screen: scan the Mac's Live Capture QR code (or enter host/port/token manually). Driven by
/// `vm.connectPhase` so it names what it's dialing the instant the QR decodes and, on failure, names the
/// cause + the fix with a clean "Try again" — never a dead spinner or a wrong "same Wi-Fi" message.
struct ConnectScreen: View {
    @ObservedObject var vm: CaptureViewModel
    @State private var showScanner = false
    @State private var showManual = false
    @State private var host = ""
    @State private var port = ""
    @State private var token = ""
    @State private var manualError: String?

    private var isConnecting: Bool {
        if case .connecting = vm.connectPhase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Connect to your Mac").font(.title2).bold()
            Text("Open the Live Capture tab in the Archive Processor Mac app and scan the QR code it shows.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)

            Button { presentScanner() } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)
            .disabled(isConnecting)

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
            Spacer()
        }
        .sheet(isPresented: $showScanner) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { payload in
                    showScanner = false
                    Task { await vm.connectFromQR(payload) }
                }
                .ignoresSafeArea()
                Button { showScanner = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white)
                }
                .padding()
            }
        }
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
                Settings ▸ Archive Capture ▸ Local Network.
                """)
        case .refused(let h, let p):
            failure("Reached the network but nothing is listening at \(h):\(p) — is Live Capture started on the Mac?")
        case .unauthorized:
            failure("Pairing code rejected — re-scan the QR (it may be stale).")
        case .badQR:
            failure("That isn't an Archive Processor pairing code.")
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
}
