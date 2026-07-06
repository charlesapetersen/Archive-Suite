import SwiftUI
import ImageIO
import UIKit

/// Main capture UI: camera preview + Box/shutter/Folder, End-segment, and a strip that shows only the
/// current in-flight work — confirmed uploads leave the phone (photos transfer to the Mac in segments).
struct CaptureScreen: View {
    @ObservedObject var vm: CaptureViewModel
    @StateObject private var camera = CameraController()
    @State private var showClearConfirm = false
    @State private var showRepairConfirm = false
    @State private var isCapturing = false

    /// Current in-flight work: document pages, plus any PENDING/FAILED marker needing attention.
    private var strip: [CapturedItem] {
        vm.items.filter { $0.type == .document || $0.state == .pending || $0.state == .failed }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if camera.authorized {
                    CameraPreview(session: camera.session)
                } else {
                    VStack(spacing: 12) {
                        Text("Camera permission needed to capture.").foregroundStyle(.white)
                        if camera.accessDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                // Connection + Re-pair: once paired the app opens straight to this screen, so this is the
                // way back to the QR scanner (switch Macs/networks). Captured photos are kept meanwhile.
                HStack {
                    Text(vm.endpoint.map { "Connected · \($0.name)" } ?? "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Re-pair") { showRepairConfirm = true }.foregroundStyle(.white)
                }
                HStack {
                    if !vm.items.isEmpty { Button("Clear") { showClearConfirm = true }.foregroundStyle(.white) }
                    if vm.items.contains(where: { $0.state == .failed }) { Button("Retry") { vm.retryFailed() }.foregroundStyle(.white) }
                    Spacer()
                    Button("End segment") { vm.finishDocumentSegment() }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Finish") { vm.finishSession() }.foregroundStyle(.white)
                }

                let uploading = vm.items.filter { $0.state == .uploading }.count
                if vm.transferFlash != nil || uploading > 0 {
                    HStack(spacing: 8) {
                        if let flash = vm.transferFlash { Text("⤴ \(flash)").foregroundStyle(.green).font(.callout) }
                        Spacer()
                        if uploading > 0 { Text("Transferring \(uploading)…").foregroundStyle(.yellow).font(.caption) }
                    }
                }

                if !strip.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(strip) { item in
                                Thumb(item: item,
                                      selected: vm.selectedItemId == item.id && !vm.armed,
                                      armed: vm.selectedItemId == item.id && vm.armed)
                                    .onTapGesture { vm.tapItem(item.id) }
                                    .onLongPressGesture { vm.toggleP10(item.id) }
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(height: 70)
                    .animation(.easeInOut(duration: 0.25), value: strip.map(\.id))
                }

                HStack {
                    Button { capture(.box) } label: { Text("Box").frame(width: 66, height: 44) }
                        .background(Color(red: 0.83, green: 0.18, blue: 0.18)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    Button { capture(.document) } label: {
                        Circle().fill(.white).frame(width: 68, height: 68).overlay(Circle().stroke(.gray, lineWidth: 3))
                    }
                    Spacer()
                    Button { capture(.folder) } label: { Text("Folder").frame(width: 66, height: 44) }
                        .background(Color(red: 0.48, green: 0.12, blue: 0.64)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .disabled(isCapturing)

                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage).font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(12)
            .background(Color(white: 0.08))
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .sheet(isPresented: Binding(get: { vm.pendingTagGroupId != nil },
                                    set: { if !$0 { vm.cancelTagSheet() } })) {
            SegmentTagSheet(recentYears: vm.recentYears) { p, y, m in
                vm.applyTagsAndContinue(priority: p, year: y, month: m)
            }
        }
        .confirmationDialog("Clear all photos?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear (\(vm.items.count))", role: .destructive) { vm.clearSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes captured photos still on this phone and can't be undone.")
        }
        .confirmationDialog("Re-pair with a Mac?", isPresented: $showRepairConfirm, titleVisibility: .visible) {
            Button("Re-pair") { vm.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disconnects from \(vm.endpoint?.name ?? "the Mac") and returns to the pairing screen so you can scan a QR (e.g. to switch Macs or networks). Captured photos are kept and upload once you reconnect.")
        }
        .alert("Photo not saved", isPresented: Binding(
            get: { vm.captureError != nil },
            set: { if !$0 { vm.captureError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.captureError = nil }
        } message: {
            Text(vm.captureError ?? "")
        }
    }

    /// Reclassify a selected page into a Box/Folder if one is selected; otherwise take a new photo.
    private func capture(_ type: GroupType) {
        if type != .document, vm.selectedItemId != nil { vm.reclassifySelected(type); return }
        guard !isCapturing else { return }
        isCapturing = true
        camera.capturePhoto { data in
            isCapturing = false
            guard let data else { return }
            guard let url = vm.persistCapturedJPEG(data) else { return }   // surfaces a blocking alert on failure
            if type == .document { vm.addDocumentPhoto(url) } else { vm.captureMarker(url, type: type) }
        }
    }
}

/// A capture strip thumbnail with an upload-state dot; loads a downsampled image off the main thread.
private struct Thumb: View {
    let item: CapturedItem
    let selected: Bool
    let armed: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Color.gray.opacity(0.4) }
            Circle().fill(stateColor).frame(width: 10, height: 10).padding(3)
            if armed {
                Color.black.opacity(0.45)
                Image(systemName: "xmark").foregroundStyle(.white).font(.headline)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 64, height: 64)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(ring, lineWidth: ring == .clear ? 0 : 3))
        .task(id: item.fileURL) { image = await Self.loadThumb(item.fileURL) }
    }

    private var stateColor: Color {
        switch item.state {
        case .uploaded: return .green
        case .uploading: return .yellow
        case .failed: return .red
        case .pending: return .gray
        }
    }
    private var ring: Color {
        if armed { return .red }
        if selected { return .blue }
        if item.priority == "P10" { return .yellow }
        return .clear
    }

    private static func loadThumb(_ url: URL, maxPixel: Int = 180) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                      kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}
