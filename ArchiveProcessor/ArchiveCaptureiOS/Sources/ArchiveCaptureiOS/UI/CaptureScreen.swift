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
            // Preview extends up under the (translucent) status bar so the camera area reaches the very
            // top of the screen; the clock/wifi/battery overlay the black letterbox (light via the dark
            // color scheme below). Still aspect-fit — WYSIWYG, no crop.
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 8) {
                // Connection + Re-pair: once paired the app opens straight to this screen, so this is the
                // way back to the QR scanner (switch Macs/networks). Captured photos are kept meanwhile.
                HStack {
                    Text(vm.endpoint.map { "Connected · \($0.name)" } ?? "Not connected")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // Backup safety net: copy what's on the phone to Photos if it won't transfer.
                    if !vm.items.isEmpty { Button("Save to phone") { vm.saveToPhone() }.foregroundStyle(.white) }
                    Button("Re-pair") { showRepairConfirm = true }.foregroundStyle(.white)
                        .accessibilityLabel("Re-pair with a Mac")
                }
                // End segment is the ONLY "done" action: a document is finished when you tap it (there is
                // no separate "Finish" — its pages already streamed to the Mac, so ending the segment sends
                // the completion signal that makes the Mac present this segment's tag card). Tagging on Mac.
                HStack {
                    if !vm.items.isEmpty { Button("Clear") { showClearConfirm = true }.foregroundStyle(.white) }
                    if vm.items.contains(where: { $0.state == .failed }) { Button("Retry") { vm.retryFailed() }.foregroundStyle(.white) }
                    Spacer()
                    Button("End segment") { vm.finishDocumentSegment() }.buttonStyle(.borderedProminent)
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
                                    .onLongPressGesture { vm.toggleQ3(item.id) }
                                    .accessibilityAction(named: "Toggle quality Q3") { vm.toggleQ3(item.id) }
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
                        .accessibilityLabel(vm.selectedItemId != nil ? "Reclassify the selected photo as a box marker"
                                                                     : "Box. Capture a box-label marker")
                    Spacer()
                    Button { capture(.document) } label: {
                        Circle().fill(.white).frame(width: 68, height: 68).overlay(Circle().stroke(.gray, lineWidth: 3))
                    }
                    .accessibilityLabel("Shutter. Capture a document page")
                    Spacer()
                    Button { capture(.folder) } label: { Text("Folder").frame(width: 66, height: 44) }
                        .background(Color(red: 0.48, green: 0.12, blue: 0.64)).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(vm.selectedItemId != nil ? "Reclassify the selected photo as a folder marker"
                                                                     : "Folder. Capture a folder-label marker")
                }
                .disabled(isCapturing)

                // W23.m8's port (W40.i-fix-ios-session-durability): the session snapshot didn't reach phone storage.
                // Its own line, because the status line is overwritten by the next capture and this lasts until a
                // later save lands: until then, an app kill costs the grouping and tags of everything shot since.
                if vm.sessionNotSaved {
                    Text("⚠︎ Session not saved to this phone — if the app closes now, recent grouping and tags are lost. Photos are safe; keep the app open.")
                        .font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }

                // Pages recovered against a session file that never reached disk. Held here, not sent, because their
                // box/folder is gone and the Mac would file them under a guess. Review is the only way out, and it
                // is the ordinary tag sheet.
                if vm.heldForReviewCount > 0 {
                    HStack {
                        Text("⚠︎ \(vm.heldForReviewCount) recovered photo(s) held — their box/folder wasn't saved.")
                            .font(.caption2).foregroundStyle(.orange)
                        Spacer()
                        Button("Review") { vm.reviewRecoveredPhotos() }.font(.caption)
                    }
                }

                if !vm.statusMessage.isEmpty {
                    Text(vm.statusMessage).font(.caption2).foregroundStyle(.white.opacity(0.6))
                }
            }
            .padding(12)
            // Extra bottom lift so the shoot buttons sit higher in the thumb zone (more ergonomic).
            .padding(.bottom, 18)
            .background(Color(white: 0.08))
        }
        .background(Color.black.ignoresSafeArea())
        // Dark scheme → white status-bar content (clock/wifi/battery) over the black preview top, and a
        // consistently dark capture UI. The tag sheet uses only adaptive colors, so it's dark-safe too.
        .preferredColorScheme(.dark)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        #if DEBUG
        .task { if E2EHarness.drives { await driveForE2E() } }
        #endif
        // Gesture-dismiss is DISABLED (interactiveDismissDisabled) so an accidental swipe can't silently
        // strand the just-ended document. The operator must choose in the sheet: Apply & continue / Skip
        // (both end the segment and send it to the Mac) or Cancel — keep shooting (End segment was a
        // mistake; keep adding to the same document). The binding's set-closure is a harmless no-op after
        // Apply/Skip (finalizeSegment clears pendingTagGroupId first).
        .sheet(isPresented: Binding(get: { vm.pendingTagGroupId != nil },
                                    set: { if !$0 { vm.cancelTagSheet() } })) {
            SegmentTagSheet(recentYears: vm.recentYears,
                            onApply: { q, y, m in vm.applyTagsAndContinue(quality: q, year: y, month: m) },
                            onCancel: { vm.cancelTagSheet() })
                .interactiveDismissDisabled(true)
        }
        .confirmationDialog("Clear all photos?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear (\(vm.items.count))", role: .destructive) { vm.clearSession() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let unUploaded = vm.items.filter { $0.state != .uploaded }
            if unUploaded.isEmpty {
                Text("All photos have been uploaded to the Mac. This clears the list and can't be undone.")
            } else {
                Text("\(unUploaded.count) photo(s) have NOT been uploaded to the Mac and will be permanently lost. This can't be undone.")
            }
        }
        .confirmationDialog("Re-pair with a Mac?", isPresented: $showRepairConfirm, titleVisibility: .visible) {
            Button("Re-pair") { vm.disconnect() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Disconnects from \(vm.endpoint?.name ?? "the Mac") and returns to the pairing screen so you can scan a QR (e.g. to switch Macs or networks). Captured photos are kept and upload once you reconnect.")
        }
        .confirmationDialog("Delete a photo the Mac doesn't have?", isPresented: Binding(
            get: { vm.pendingDeleteId != nil },
            set: { if !$0 { vm.pendingDeleteId = nil } }
        ), titleVisibility: .visible) {
            Button("Save to Photos & delete") { vm.confirmDelete(saveToPhotos: true) }
            Button("Delete permanently", role: .destructive) { vm.confirmDelete(saveToPhotos: false) }
            Button("Cancel", role: .cancel) { vm.pendingDeleteId = nil }
        } message: {
            Text("This photo, or a change to it, hasn't reached the Mac yet. Its transfer stops first. Deleting it permanently loses it forever; saving it to Photos keeps a copy there.")
        }
        .alert("Photo not saved", isPresented: Binding(
            get: { vm.captureError != nil },
            set: { if !$0 { vm.captureError = nil } }
        )) {
            Button("OK", role: .cancel) { vm.captureError = nil }
        } message: {
            Text(vm.captureError ?? "")
        }
        .alert("Photos missing", isPresented: Binding(
            get: { vm.restoreWarning != nil },
            set: { if !$0 { vm.restoreWarning = nil } }
        )) {
            Button("OK", role: .cancel) { vm.restoreWarning = nil }
        } message: {
            Text(vm.restoreWarning ?? "")
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

    #if DEBUG
    /// The E2E driver (Debug/E2EHarness.swift): per inbox JPEG, the Android driver's taps — shutter, End
    /// segment, Skip — then wait until every page and segment signal has reached the Mac.
    private func driveForE2E() async {
        let docs = E2EHarness.inbox()
        guard !docs.isEmpty else { E2EHarness.status("FAIL inbox empty"); return }
        for (i, doc) in docs.enumerated() {
            let n = i + 1
            guard E2EHarness.stage(doc) else { E2EHarness.status("FAIL staging doc \(n)"); return }
            guard await E2EHarness.wait(10, { !isCapturing }) else { E2EHarness.status("FAIL shutter busy \(n)"); return }
            capture(.document)
            guard await E2EHarness.wait(10, {
                !isCapturing && vm.items.contains { $0.groupId == vm.currentGroupId && $0.type == .document }
            }) else {
                E2EHarness.status("FAIL capture \(n): \(vm.captureError ?? vm.statusMessage)"); return
            }
            E2EHarness.status("captured \(n)")
            try? await Task.sleep(nanoseconds: 1_500_000_000)   // a beat for the script's screenshot
            vm.finishDocumentSegment()                         // "End segment"
            guard await E2EHarness.wait(5, { vm.pendingTagGroupId != nil }) else {
                E2EHarness.status("FAIL no tag sheet \(n): \(vm.statusMessage)"); return
            }
            vm.applyTagsAndContinue(quality: nil, year: nil, month: nil)   // "Skip (tag on Mac)"
            E2EHarness.status("ended \(n)")
        }
        guard await E2EHarness.wait(120, { vm.e2eSettled }) else {
            E2EHarness.status("FAIL not settled: \(vm.items.count) page(s) on the phone; \(vm.statusMessage)"); return
        }
        E2EHarness.status("DONE \(docs.count)")
    }
    #endif
}

/// A capture strip thumbnail with an upload-state dot (teal, with a check badge, once saved to Photos); loads a
/// downsampled image off the main thread.
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
            // Saved to Photos: safe on the phone, so it must not read as failed (Android's saved badge).
            if item.savedToPhone == true && !armed {
                Text("✓").font(.caption2.bold()).foregroundStyle(.white)
                    .frame(width: 14, height: 14).background(Circle().fill(Self.savedTeal))
                    .padding(2).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
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
        // VoiceOver: type + status (+ Q3 / delete-armed), Android's TalkBack label, so the strip isn't unlabeled.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Select it to reclassify it with Box or Folder. Activate it twice more to delete it.")
    }

    private static let savedTeal = Color(red: 0x30 / 255, green: 0xB0 / 255, blue: 0xC7 / 255)

    private var a11yLabel: String {
        let type: String
        switch item.type {
        case .document: type = "Document page"
        case .box: type = "Box marker"
        case .folder: type = "Folder marker"
        }
        let status: String
        if item.savedToPhone == true { status = "saved to Photos" }
        else if item.needsReview == true { status = "held for review, not sent" }
        else {
            switch item.state {
            case .uploaded: status = "sent to Mac"
            case .uploading: status = "sending to Mac"
            case .failed: status = "upload failed, will retry"
            case .pending: status = "queued to send"
            }
        }
        var label = "\(type), \(status)"
        if item.quality == "Q3" { label += ", quality Q3" }
        if armed { label += ", tap again to delete" }
        return label
    }

    private var stateColor: Color {
        if item.savedToPhone == true { return Self.savedTeal }
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
        if item.quality == "Q3" { return .yellow }
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
