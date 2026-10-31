import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if vm.endpoint == nil {
                ConnectScreen(vm: vm)
            } else {
                CaptureScreen(vm: vm)
            }
        }
        .onChange(of: scenePhase) { old, new in
            if old == .background && new != .background { vm.returnedFromBackground() }
        }
        #if DEBUG
        .task { await pairForE2E() }
        #endif
    }

    #if DEBUG
    /// The E2E's pairing (Debug/E2EHarness.swift): the scanner's own path, fed the payload at launch.
    private func pairForE2E() async {
        guard vm.endpoint == nil, let payload = E2EHarness.pairPayload else { return }
        await vm.connectFromQR(payload)
        E2EHarness.status(vm.endpoint != nil ? "paired" : "FAIL pairing: \(vm.connectPhase)")
    }
    #endif
}
