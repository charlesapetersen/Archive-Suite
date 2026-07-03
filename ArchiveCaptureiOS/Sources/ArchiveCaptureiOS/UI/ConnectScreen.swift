import SwiftUI

/// Pairing screen: scan the Mac's Live Capture QR code (or enter host/port/token manually).
struct ConnectScreen: View {
    @ObservedObject var vm: CaptureViewModel
    @State private var showScanner = false
    @State private var connecting = false
    @State private var errorText: String?
    @State private var showManual = false
    @State private var host = ""
    @State private var port = ""
    @State private var token = ""

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "qrcode.viewfinder").font(.system(size: 64)).foregroundStyle(.tint)
            Text("Connect to your Mac").font(.title2).bold()
            Text("Open the Live Capture tab in the Archive Processor Mac app and scan the QR code it shows.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal)

            Button { errorText = nil; showScanner = true } label: {
                Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).controlSize(.large).padding(.horizontal)

            if connecting { ProgressView("Connecting…") }
            if let e = errorText {
                Text(e).foregroundStyle(.red).font(.callout).multilineTextAlignment(.center).padding(.horizontal)
            }

            DisclosureGroup("Enter manually", isExpanded: $showManual) {
                VStack(spacing: 8) {
                    TextField("Host (e.g. 192.168.1.5)", text: $host)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    TextField("Port", text: $port).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
                    TextField("Token", text: $token)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("Connect") { manualConnect() }
                        .buttonStyle(.bordered)
                        .disabled(host.isEmpty || port.isEmpty || token.isEmpty || connecting)
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
                    run { await vm.connectFromQR(payload) }
                }
                .ignoresSafeArea()
                Button { showScanner = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.largeTitle).foregroundStyle(.white)
                }
                .padding()
            }
        }
    }

    private func manualConnect() {
        guard let p = Int(port) else { errorText = "Port must be a number."; return }
        run { await vm.connect(host: host.trimmingCharacters(in: .whitespaces), port: p,
                               token: token.trimmingCharacters(in: .whitespaces)) }
    }

    private func run(_ op: @escaping () async -> Bool) {
        connecting = true; errorText = nil
        Task {
            let ok = await op()
            connecting = false
            if !ok { errorText = "Couldn't connect. Make sure your phone and Mac are on the same Wi-Fi network." }
        }
    }
}
