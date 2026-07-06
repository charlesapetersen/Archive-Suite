import SwiftUI

struct ContentView: View {
    @StateObject private var vm = CaptureViewModel()

    var body: some View {
        if vm.endpoint == nil {
            ConnectScreen(vm: vm)
        } else {
            CaptureScreen(vm: vm)
        }
    }
}
