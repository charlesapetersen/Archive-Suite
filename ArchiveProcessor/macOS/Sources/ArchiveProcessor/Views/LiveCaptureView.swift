import SwiftUI
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Receiving end of Live Capture: advertises the Mac, shows a pairing QR for the phone, and
/// displays photos streaming in — grouped exactly as marked on the phone. "Process" stages the
/// ordered, pre-grouped photos into the main Files view for the normal OCR run.
struct LiveCaptureView: View {
    @ObservedObject var session: CaptureSession
    @ObservedObject var processor: OCRProcessor
    @ObservedObject var liveProc: LiveCaptureProcessor
    /// Switch the app back to the Files tab after staging captured photos for processing.
    var onProcess: () -> Void

    /// App-wide choice (Settings ⌘,): live streaming vs. staging for a later batch run.
    @AppStorage(DefaultsKeys.liveProcessingMode) private var liveProcessingMode: String = LiveProcessingMode.stage.rawValue
    /// Where finalized live collections are written (shared with Process Files). Empty → Downloads.
    @AppStorage(DefaultsKeys.outputDirectory) private var outputDirPath: String = ""
    /// Only to seed the per-segment retry sheet when there is no session config to read it from.
    @AppStorage(DefaultsKeys.selectedProvider) private var selectedProvider: LLMProvider = .gemini

    // A1 — shared Processing-list state: which segment is expanded, and the two per-item action sheets.
    @State private var expandedSegmentID: String?
    @State private var textViewerTarget: SegmentTextTarget?
    @State private var modelChoiceTarget: ModelChoiceTarget?

    struct SegmentTextTarget: Identifiable { let id: String }
    struct ModelChoiceTarget: Identifiable {
        let groupId: String
        let includeRotation: Bool
        var id: String { groupId + (includeRotation ? "-rot" : "-mdl") }
    }

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 300, maxWidth: 360)
                .padding()
            capturePanel
                .padding()
        }
        // After rotation review, changed segments' PDFs regenerate before the collection-naming sheet
        // appears — `isFinalizing` is true but no sheet is up, which used to look hung. Surface a throbber
        // so the operator sees work is still happening. (During the finalize move itself the sheet is up
        // with its own spinner, so this stays gated off then.)
        .overlay {
            if liveProc.isFinalizing && !liveProc.showFinalizeSheet && !liveProc.showRotationReview {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Finishing — processing segments…").font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .onAppear {
            SystemTagsProvider.shared.warmUp()   // prime subject autocomplete
            if ProcessInfo.processInfo.environment["LIVECAPTURE_AUTOSTART"] == "1", !session.serverRunning {
                session.start()
            }
        }
        .onDisappear { /* keep the session/server running across tab switches */ }
        // Auto-advancing tag card: pops up for each completed document segment as it arrives,
        // then advances to the next (box/folder markers need no card).
        .sheet(item: Binding(
            get: { session.pendingTagGroup },
            // Dismissal is not a semantic action. Only the card's explicit Apply or Skip buttons may
            // resolve the group; treating Escape/click-outside as Skip silently discards typed metadata.
            set: { _ in }
        )) { group in
            SegmentTagCard(group: group, session: session)
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $liveProc.showFinalizeSheet) {
            CollectionFinalizeSheet(liveProc: liveProc)
        }
        .sheet(isPresented: $liveProc.showRotationReview) {
            LiveRotationReviewSheet(liveProc: liveProc)
        }
        // Per-item "retry with model" / "rotate & re-run": pick provider/model (+ rotation), then re-OCR
        // just this segment via the generalized retry path.
        .sheet(item: $modelChoiceTarget) { target in
            ModelChoiceSheet(
                title: target.includeRotation ? "Rotate & re-run" : "Retry with model",
                subtitle: "Re-run OCR for this segment; its old staged output is replaced.",
                includeRotation: target.includeRotation,
                // Price this retry. Without a count `ModelChoiceSheet` renders no cost line at all, so
                // switching provider/model here — which CAN move you onto a far dearer model — was silent.
                fileCountForEstimate: liveProc.statuses.first { $0.id == target.groupId }?.pageCount,
                // The SESSION's provider/model, not the app-wide selection: `activateProcessingIfNeeded`
                // snapshots and LOCKS the config at session start precisely so a mid-session Settings
                // change can't alter a running session, so the live selection would misreport what OCR'd
                // this segment. The fallback is unreachable today (no session ⇒ no retry list) but keeps
                // the expression total.
                initialProvider: session.config?.provider ?? selectedProvider,
                initialModel: session.config?.model ?? ModelSelectionStore.savedModel(for: selectedProvider),
                initialThinking: session.config?.thinkingLevel ?? .low,
                onApply: { provider, model, thinking, apiKey, rotation in
                    let ov = LiveCaptureProcessor.OCROverride(
                        provider: provider, model: model, thinkingLevel: thinking,
                        apiKey: apiKey, rotation: rotation)
                    liveProc.retryFailed(groupIds: [target.groupId], override: ov)
                    modelChoiceTarget = nil
                },
                onCancel: { modelChoiceTarget = nil })
        }
        // Per-item "view text": the retained OCR text + any error reason.
        .sheet(item: $textViewerTarget) { target in
            SegmentTextViewerSheet(
                text: liveProc.retainedText(for: target.id),
                errorMessage: liveProc.statuses.first(where: { $0.id == target.id })?.errorMessage,
                onDismiss: { textViewerTarget = nil })
        }
    }

    // MARK: A1 — shared Processing list (per-item actions)

    private func performSegmentAction(_ action: ItemAction, on id: String) {
        switch action {
        case .retry:
            liveProc.retryFailed(groupIds: [id])
        case .retryWithModel:
            modelChoiceTarget = ModelChoiceTarget(groupId: id, includeRotation: false)
        case .changeRotation:
            modelChoiceTarget = ModelChoiceTarget(groupId: id, includeRotation: true)
        case .viewText:
            textViewerTarget = SegmentTextTarget(id: id)
        case .revealFiles:
            let urls = liveProc.stagedURLs(for: id)
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            else { session.revealBackupFolder() }
        case .reclassify, .fileAsImageOnly:
            break   // not offered by SegmentItem (reclassify is Files-only; image-only is auto per §4a)
        }
    }

    // MARK: Left — connection / pairing

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Live Capture")
                        .font(.title).fontWeight(.bold)
                    Spacer()
                    // Obvious one-click access to the durable backup folder: every photo the phone sends
                    // is kept there until the run's output is fully written, so the operator can recover
                    // and copy the originals in Finder if anything goes wrong (even if the app can't relaunch).
                    Button {
                        session.revealBackupFolder()
                    } label: {
                        Label("Backup Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .help("Open the Live Capture backup folder in Finder (~/Pictures/Archive Processor Live Capture). Every photo received from the phone is stored there until this run's output is fully written — so you can recover and copy the originals if anything fails.")
                }

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            let running = session.receiverActive
                            Circle().fill(running ? .green : .secondary).frame(width: 8, height: 8)
                            Text(running ? "Active" : "Stopped").font(.callout).fontWeight(.medium)
                            Spacer()
                            if running {
                                Button("Stop") { session.stop() }
                            } else {
                                Button("Start") { session.start() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        // DUAL receiver status: the Mac always listens on the LAN AND (when signed into Drive)
                        // watches Google Drive — both run at once, so a single QR serves any phone transport.
                        if session.receiverActive {
                            // PHONE connection (B4-ii): split "a phone is actively here" (green · derived from
                            // the /phone/status heartbeat + recent ingest via `phoneConnected`) from mere
                            // "receiver listening" below — so a stale green receiver dot never reads as "still
                            // paired" after the phone re-pairs or walks away.
                            HStack(spacing: 6) {
                                Circle().fill(session.phoneConnected ? .green : .secondary).frame(width: 6, height: 6)
                                Image(systemName: "iphone").font(.caption2).foregroundStyle(.secondary)
                                Text(session.phoneConnected
                                     ? (session.connectedDeviceName.map { "Connected · \($0)" } ?? "Connected")
                                     : "No phone connected")
                                    .font(.caption)
                                    .foregroundStyle(session.phoneConnected ? .primary : .secondary)
                            }
                            HStack(spacing: 6) {
                                Circle().fill(session.serverRunning ? .green : .secondary).frame(width: 6, height: 6)
                                Image(systemName: "wifi").font(.caption2).foregroundStyle(.secondary)
                                Text(session.serverRunning ? "Listening (Wi-Fi / USB)" : "LAN off").font(.caption)
                            }
                            HStack(spacing: 6) {
                                Circle().fill(session.driveWatching ? .green : .secondary).frame(width: 6, height: 6)
                                Image(systemName: "cloud").font(.caption2).foregroundStyle(.secondary)
                                Text(session.driveWatching ? "Watching Drive"
                                     : (session.isDriveSignedIn ? "Drive starting…" : "Drive off — sign in (Settings ⌘,)"))
                                    .font(.caption)
                            }
                        }
                        Text(session.statusMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                // B2: the Processing status/segment list lives in its own view that OWNS the observation of
                // `liveProc` (and `session`). When a segment's OCR/tag phase changes while the per-segment
                // tag card sheet is up, SwiftUI invalidates THIS child directly (it subscribed to liveProc),
                // so "N/M segments processed" and the per-row "OCR…/Tagging…/Staged" stay live behind the
                // modal instead of freezing until the sheet is dismissed.
                LiveProcessingBox(
                    liveProc: liveProc,
                    session: session,
                    liveMode: liveProcessingMode == LiveProcessingMode.live.rawValue,
                    expandedSegmentID: $expandedSegmentID,
                    onAction: performSegmentAction)

                // Same setting as the Process Files output folder (DefaultsKeys.outputDirectory, one source
                // of truth for both panes). Relevant only in "Process live" mode, where segments finalize
                // here; in "Stage for later" the picker grays out because captures hand off to Process Files,
                // which files them from there. Grays the control only — the ? help stays tappable to explain
                // why. Per the settings-UX convention (every setting: ? help + gray-out when irrelevant).
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(outputDirPath.isEmpty ? "Downloads (default)" : URL(fileURLWithPath: outputDirPath).lastPathComponent)
                                .font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Choose…") { chooseOutputFolder() }.font(.caption)
                        }
                        if liveProcessingMode != LiveProcessingMode.live.rawValue {
                            Text("Set in Process Files for staged captures — they're filed there, not here.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(6)
                    .disabled(liveProcessingMode != LiveProcessingMode.live.rawValue)
                } label: {
                    HStack(spacing: 6) {
                        Text("Output folder")
                        HelpButton(text: "Where finalized Process live collections are written. This is the SAME setting as the Process Files output folder — one source of truth for both panes — and defaults to your Downloads folder if unset. Set it before finishing a Process live session. In Stage for later mode it's grayed here because captures hand off to Process Files, which files them to this same folder from there.")
                    }
                }

                if session.serverRunning, session.paired {
                    GroupBox("Phone") {
                        HStack(spacing: 6) {
                            // Green only while the phone is actually being heard from (`phoneConnected`); a
                            // paired-but-quiet phone reads "Paired (idle)" rather than a misleading green.
                            Image(systemName: "iphone.gen3").foregroundStyle(session.phoneConnected ? .green : .secondary)
                            Text(session.phoneConnected
                                 ? (session.connectedDeviceName.map { "Connected · \($0)" } ?? "Connected")
                                 : (session.connectedDeviceName.map { "Paired (idle) · \($0)" } ?? "Paired (idle)"))
                                .font(.callout)
                            Spacer()
                            Button("Show QR") { session.unpairDisplay() }.font(.caption)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                    }
                } else if session.serverRunning, let payload = pairingPayload {
                    GroupBox("Pair the phone") {
                        VStack(spacing: 8) {
                            if let qr = Self.qrImage(from: payload) {
                                Image(nsImage: qr)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 200, height: 200)
                            }
                            Text("Scan in Archive Capture — one code works over USB, Wi-Fi, or Cloud (Google Drive).")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            let ips = Self.allIPv4Candidates()
                            if let ip = Self.primaryIPv4() ?? ips.first {
                                Text("\(ip):\(session.listenPort)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            // When signed into Drive, the same QR also carries the relay code (additive `relay`
                            // key); a phone that picks Cloud reads it. Shown so it can be typed for manual entry.
                            if session.isDriveSignedIn {
                                Text("Cloud relay code: \(session.token)")
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary).textSelection(.enabled)
                            }
                            // Other interfaces (e.g. bridge100 when the Mac itself is the hotspot) — the
                            // QR uses the primary, but the operator can try an alternate via manual entry.
                            let others = ips.filter { $0 != (Self.primaryIPv4() ?? ips.first) }
                            if !others.isEmpty {
                                Text("also: " + others.joined(separator: ", "))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                            }
                            // The airport-Wi-Fi failure mode we hit: many public/guest networks isolate
                            // clients so the phone can't reach the Mac even on the same Wi-Fi — the scan
                            // just does nothing. Name the fix so the operator isn't stuck.
                            Text("Phone not connecting? This Wi-Fi may block device-to-device connections (common on public / guest / hotel networks). Fixes: use a **USB cable** (Android), or turn on a **personal hotspot** and join both devices to it.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// ONE combined pairing payload encoded in the QR: `{host, port, token, name}` PLUS an OPTIONAL `relay`
    /// token (emitted only while the Mac is signed into the Drive relay). The extra key is ADDITIVE — an
    /// older companion that ignores it still pairs over LAN byte-for-byte (when not signed in the payload is
    /// exactly the original four keys); a current companion reads `relay` and can upload via Drive if the
    /// operator picks Cloud. W16.lan2 split the two credentials: `token` is the high-entropy LAN/USB bearer
    /// (`CaptureServer`), while `relay` stays the SPEC-pinned 6-char Drive-relay code (the value
    /// `DriveObjectStore` stamps as `appProperties.relayToken`). Both are opaque to the companions, so the
    /// only migration cost of the LAN split is one QR re-scan per phone.
    private var pairingPayload: String? {
        guard session.serverRunning, let ip = Self.primaryIPv4() else { return nil }
        var dict: [String: Any] = [
            "host": ip,
            "port": Int(session.listenPort),
            "token": session.lanToken,
            "name": Host.current().localizedName ?? "Mac"
        ]
        if session.isDriveSignedIn { dict["relay"] = session.token }   // optional Cloud path (additive key)
        return (try? JSONSerialization.data(withJSONObject: dict)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Right — live grouped photos

    private var capturePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Captured")
                    .font(.headline)
                Text("\(session.photos.count) photo\(session.photos.count == 1 ? "" : "s") · \(session.groups.count) group\(session.groups.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                if session.phonePendingActive {
                    Label("phone sending \(session.phonePendingCount)", systemImage: "iphone.and.arrow.forward")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if !session.photos.isEmpty {
                    // Clear resets BOTH panes as one (B1): CaptureSession.clear() empties the Captured pane
                    // (received photos → Trash, recoverable) and clearSessionState() resets the Processing
                    // pane's in-memory segment/staged state (also cancels any pending Finish + summary). No
                    // on-disk deletion beyond what session.clear() already does; staged _processed output
                    // stays recoverable in the backup folder (Recovery Core Directive intact).
                    Button("Clear") { session.clear(); liveProc.clearSessionState() }
                    if liveProcessingMode != LiveProcessingMode.live.rawValue {
                        Button("Process \(session.photos.count) →") { stageForProcessing() }
                            .buttonStyle(.borderedProminent)
                            .disabled(processor.isProcessing)
                    } else if session.processingMode == .undecided {
                        // Live mode, but the session was never activated — e.g. photos recovered after
                        // a restart. Resume the live pipeline (OCR + per-segment tag cards) so these
                        // photos can be processed instead of only cleared.
                        Button("Process \(session.photos.count) →") { session.activateProcessingIfNeeded() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        // Live mode, session active. Always show Finish so the user sees where the
                        // session ends — grayed with a spinner while segments are still being OCR'd/
                        // tagged (so it's clear work is happening, not just a "Clear" button), and
                        // enabled once at least one segment has finished (staged). If Finish is tapped
                        // while segments are still processing, we WAIT for them (pendingFinish) so none are
                        // missing from the rotation review, and any un-tagged/open segment is recovered.
                        let processing = liveProc.statuses.contains { $0.phase == .ocr || $0.phase == .tagging }
                        HStack(spacing: 8) {
                            if liveProc.pendingFinish {
                                ProgressView().controlSize(.small)
                                if session.phonePendingActive {
                                    Text("Finishing — the phone still has \(session.phonePendingCount) photo(s) to send. Waiting for them to arrive…")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Text("Finishing when processing completes (\(liveProc.processingCount) left). Keep shooting to add another segment; tap Finish again to include one you didn't tag.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else if processing && liveProc.staged.isEmpty {
                                ProgressView().controlSize(.small)
                                Text("Processing…").font(.caption).foregroundStyle(.secondary)
                            }
                            Button(liveProc.staged.isEmpty ? "Finish session →" : "Finish session (\(liveProc.staged.count)) →") {
                                liveProc.requestFinish()
                            }
                            .buttonStyle(.borderedProminent)
                            // Enabled once anything is captured (not only when staged): Finish also recovers
                            // an un-ended/un-tagged segment (completeAllOpenDocGroups). Kept TAPPABLE while a
                            // finish is pending so a newly-added, still-un-tagged segment can be recovered by
                            // re-tapping (no deadlock) — new photos extend the same pending finish rather than
                            // cancelling it. Only blocked during the actual file move (isFinalizing).
                            .disabled(liveProc.statuses.isEmpty || liveProc.isFinalizing)
                        }
                    }
                }
            }
            .padding(.bottom, 8)

            Divider()

            if session.photos.isEmpty {
                Spacer()
                if let summary = liveProc.finalizeSummary {
                    // Session complete: the captured photos have been processed & filed, so the pane
                    // shows the result here in their place until the next photo starts a new batch.
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.green)
                        Text(summary)
                            .font(.title3).multilineTextAlignment(.center)
                        Text("Shoot on the phone to start a new batch.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "camera.badge.clock").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text(session.receiverActive ? "Waiting for photos…\nShoot on the phone; they'll appear here grouped."
                                                   : "Start the server, then pair the phone.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(session.groups.enumerated()), id: \.element.id) { idx, group in
                            groupSection(index: idx + 1, group: group)
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }

    private func groupSection(index: Int, group: CaptureGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let color = group.type.colorTag {
                    Circle().fill(color == "Red" ? .red : .purple).frame(width: 8, height: 8)
                }
                Text("Group \(index) · \(group.type.rawValue.capitalized)")
                    .font(.subheadline).fontWeight(.medium)
                Text("\(group.photos.count)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                ForEach(group.photos) { photo in
                    ArchiveThumbnail(url: photo.url, maxSize: 300)
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        .overlay(alignment: .topTrailing) {
                            Button { session.removePhoto(photo) } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .buttonStyle(.plain).padding(4)
                        }
                }
            }
        }
        .padding(10)
        .background(
            group.type == .box ? Color.red.opacity(0.06) :
            group.type == .folder ? Color.purple.opacity(0.06) : Color.gray.opacity(0.05)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Handoff

    /// Pick where finalized live collections are written (persists to the shared output-directory setting).
    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { outputDirPath = url.path }
    }

    private func stageForProcessing() {
        let (files, boundaries, types, priorities, years, months, subjects) = session.orderedFilesAndGroups()
        guard !files.isEmpty else { return }
        processor.stagedCaptureFiles = files
        processor.stagedCaptureBoundaries = boundaries
        processor.stagedCaptureTypes = types
        processor.stagedCapturePriorities = priorities
        processor.stagedCaptureYears = years
        processor.stagedCaptureMonths = months
        processor.stagedCaptureSubjects = subjects
        onProcess()
    }

    // MARK: Helpers

    static func qrImage(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    /// Primary LAN IPv4 (prefers en0/en1) for the pairing payload.
    static func primaryIPv4() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }
            let family = ptr.pointee.ifa_addr.pointee.sa_family
            guard family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            // Decode the null-terminated C string without the deprecated [CChar] String(cString:).
            address = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if name == "en0" { break }   // prefer Wi-Fi/primary
        }
        return address
    }

    /// Every non-loopback IPv4 the Mac currently has (any interface), for the "try an alternate"
    /// hint — on a personal hotspot the reachable address is often not en0 (e.g. bridge100).
    static func allIPv4Candidates() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING),
                  (flags & IFF_LOOPBACK) == 0,
                  ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(ptr.pointee.ifa_addr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                        &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let ip = String(decoding: host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if !ip.isEmpty, ip != "127.0.0.1", !result.contains(ip) { result.append(ip) }
        }
        return result
    }
}

// MARK: - Processing status box (B2: owns liveProc observation so it refreshes behind the tag-card sheet)

/// The Live Capture "Processing" GroupBox, extracted into its own view so it **independently observes**
/// `LiveCaptureProcessor` (and `CaptureSession`). Because this child subscribes to `liveProc` directly,
/// SwiftUI re-renders it whenever a segment's phase/progress changes — even while the parent
/// `LiveCaptureView` is presenting the per-segment tag card sheet (whose modal presentation otherwise left
/// the parent-rendered status frozen). View-only fix; the mapping into the shared row model + the per-item
/// action wiring are unchanged (moved verbatim from `LiveCaptureView`).
private struct LiveProcessingBox: View {
    @ObservedObject var liveProc: LiveCaptureProcessor
    @ObservedObject var session: CaptureSession
    let liveMode: Bool
    @Binding var expandedSegmentID: String?
    let onAction: (ItemAction, String) -> Void

    /// Segments mapped into the shared read model. Actions + provider·model line only when expanded, so
    /// collapsed rows stay compact in the narrow control panel.
    private var segmentItems: [any ProcessableItem] {
        let pm = session.config.map { "\($0.provider.rawValue) · \($0.model.displayName)" }
        return liveProc.statuses.map { s in
            let expanded = (expandedSegmentID == s.id)
            return SegmentItem(status: s,
                               ocrText: liveProc.retainedText(for: s.id),
                               providerModel: expanded ? pm : nil,
                               expanded: expanded)
        }
    }

    var body: some View {
        GroupBox("Processing") {
            VStack(alignment: .leading, spacing: 8) {
                Label(liveMode ? "Process live" : "Stage for later",
                      systemImage: liveMode ? "bolt.fill" : "tray.and.arrow.down")
                    .font(.callout).fontWeight(.medium)
                Text(liveMode ? "Each segment is OCR'd & tagged as you capture; finish the session to name collections."
                              : "Captures collect here; use Process to send them to the Files tab.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Change in Settings (⌘,).").font(.caption2).foregroundStyle(.tertiary)

                if liveMode, let cfg = session.config {
                    Text(cfg.summary).font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if liveMode, !liveProc.statuses.isEmpty {
                    Divider()
                    // "Processed" = staged OR filed-with-a-warning (succeededNoText / W23.h5's
                    // succeededPlaceholderImage are warnings, not in-flight, so they count as done).
                    let done = liveProc.statuses.filter {
                        $0.phase == .staged || $0.phase == .succeededNoText || $0.phase == .succeededPlaceholderImage
                    }.count
                    Text("\(done)/\(liveProc.statuses.count) segments processed")
                        .font(.caption).foregroundStyle(.secondary)
                    // Shared, detailed, retry-capable list (reasons + per-item actions on expand).
                    // Min height + internal scroll so the box hosts disclosure without collapsing.
                    ScrollView {
                        ProcessableItemListView(
                            items: segmentItems,
                            selection: $expandedSegmentID,
                            badgeStyle: .dot,
                            actions: ItemActionHandler { action, id in onAction(action, id) })
                    }
                    .frame(minHeight: 120, maxHeight: 280)
                    // Bulk footer = G1 ("Retry failed only") — the all-failed case of the same
                    // per-item retry path. `succeededNoText` docs are excluded from failedGroupIds,
                    // so the count no longer over-counts a successfully-filed image-only doc.
                    if !liveProc.failedGroupIds.isEmpty {
                        Button("Retry \(liveProc.failedGroupIds.count) failed") {
                            liveProc.retryFailed(groupIds: liveProc.failedGroupIds)
                        }
                        .font(.caption).foregroundStyle(.red)
                    }
                }
            }
            .padding(6)
        }
    }
}

/// Auto-advancing tag card for one completed document segment during Live Capture. Subjects are the
/// piece the phone doesn't capture; year/month/priority default to the phone's values and are editable.
/// Built for keyboard speed: type subjects, ↑/↓ to pick a suggestion, ⇥ to autocomplete, ⏎ to add
/// (⏎ on an empty field saves), ⌫ on an empty field deletes the previous tag, esc clears a draft.
private struct SegmentTagCard: View {
    let group: CaptureGroup
    @ObservedObject var session: CaptureSession
    /// Observed so the "building suggestions…" note clears the moment the Spotlight gather finishes.
    @ObservedObject private var tagsProvider = SystemTagsProvider.shared

    @State private var subjects: [String] = []
    @State private var input: String = ""
    @State private var suggestions: [String] = []
    @State private var highlighted: Int = -1     // -1 = typed text is the candidate; ≥0 = a suggestion
    @State private var yearText: String = ""
    @State private var month: Int? = nil
    @State private var priority: String? = nil
    /// W23.m7: Save/Skip only resolve the card once the decision is durably in the session manifest. When
    /// the write fails the session rolls its state back — the card stays up with everything typed still
    /// here — so the operator needs to be TOLD, not left tapping a button that appears to do nothing.
    @State private var persistFailure: String? = nil

    private let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tag this segment").font(.title2).fontWeight(.semibold)
            Text("\(group.photos.count) page\(group.photos.count == 1 ? "" : "s"). Subjects become archive tags; date & priority came from the phone.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.photos) { photo in
                        ArchiveThumbnail(url: photo.url, maxSize: 320)
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    }
                }
            }

            subjectsSection

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Year").font(.caption).foregroundStyle(.secondary)
                    TextField("YYYY", text: $yearText)
                        .frame(width: 70)
                        .onChange(of: yearText) { _, v in yearText = String(v.filter(\.isNumber).prefix(4)) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Month").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $month) {
                        Text("—").tag(Int?.none)
                        ForEach(1...12, id: \.self) { m in Text(monthNames[m - 1]).tag(Int?.some(m)) }
                    }.labelsHidden().frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Priority").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $priority) {
                        Text("—").tag(String?.none)
                        ForEach(["P10", "P9", "P8", "P7"], id: \.self) { p in Text(p).tag(String?.some(p)) }
                    }.labelsHidden().frame(width: 80)
                }
                Spacer()
            }

            Text("↑↓ pick · ⇥ complete · ⏎ add (⏎ on empty saves) · ⌫ delete last · esc clear draft")
                .font(.caption2).foregroundStyle(.tertiary)

            if let persistFailure {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(persistFailure)
                }
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Skip") { skip() }
                Spacer()
                Button("Save ▸") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: input) { _, _ in recompute() }
        .onAppear {
            persistFailure = nil   // reset with the other fields, so one card's failure can't haunt the next
            let existing = session.macTags[group.id]
            subjects = existing?.subjects ?? []
            yearText = (existing?.year ?? group.year).map(String.init) ?? ""
            month = existing?.month ?? group.month
            priority = existing?.priority ?? group.priority
        }
    }

    // MARK: Subjects (keyboard-driven autocomplete)

    private var subjectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Subjects").font(.callout).fontWeight(.medium)
                // The Spotlight tag index is still gathering — tell the operator, so an empty suggestion
                // list reads as "still loading" rather than "no matching tags." Clears when the query finishes.
                if !tagsProvider.isReady {
                    ProgressView().controlSize(.small)
                    Text("building tag suggestions…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            FlowLayout(spacing: 6) {
                ForEach(subjects, id: \.self) { tag in
                    TagChip(text: tag) { subjects.removeAll { $0 == tag } }
                }
                KeyboardTokenField(
                    text: $input,
                    placeholder: subjects.isEmpty ? "Add subject…" : "",
                    onMoveUp: { moveHighlight(-1) },
                    onMoveDown: { moveHighlight(1) },
                    onTab: { onTab() },
                    onReturn: { onReturn() },
                    onDeleteWhenEmpty: { deletePrevious() },
                    onEscape: { onEscape() },
                    focusOnAppear: true
                )
                .frame(minWidth: 140, minHeight: 22)
            }
            .padding(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element) { idx, s in
                        HStack(spacing: 6) {
                            Image(systemName: "tag").font(.caption2).foregroundStyle(.secondary)
                            Text(s).font(.caption)
                            Spacer()
                            if idx == highlighted {
                                Text("⏎").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4).padding(.horizontal, 8)
                        .background(idx == highlighted ? Color.accentColor.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { commit(s) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            }
        }
    }

    // MARK: Keyboard actions

    private func recompute() {
        let p = input.trimmingCharacters(in: .whitespaces)
        suggestions = p.isEmpty ? [] : SystemTagsProvider.shared.suggestions(prefix: input, excluding: subjects, limit: 6)
        highlighted = -1   // the typed text is the default candidate; arrows dive into the list
    }

    private func moveHighlight(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        if highlighted < 0 {
            highlighted = delta > 0 ? 0 : suggestions.count - 1
        } else {
            highlighted = (highlighted + delta + suggestions.count) % suggestions.count
        }
    }

    private func commit(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        input = ""; suggestions = []; highlighted = -1
        guard !t.isEmpty, !subjects.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        subjects.append(t)
        SystemTagsProvider.shared.register([t])
    }

    /// Return: the highlighted suggestion if one is chosen, else the typed text.
    private func returnCandidate() -> String? {
        if highlighted >= 0, highlighted < suggestions.count { return suggestions[highlighted] }
        let t = input.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// Tab (autocomplete): the highlighted suggestion, else the top suggestion, else the typed text.
    private func tabCandidate() -> String? {
        if highlighted >= 0, highlighted < suggestions.count { return suggestions[highlighted] }
        if let first = suggestions.first { return first }
        let t = input.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func onReturn() -> Bool {
        if let c = returnCandidate() { commit(c); return true }
        save(); return true                 // empty field → save & advance
    }

    private func onTab() -> Bool {
        if let c = tabCandidate() { commit(c); return true }
        return false                        // empty field → let focus move to Year
    }

    private func deletePrevious() -> Bool {
        guard !subjects.isEmpty else { return false }
        subjects.removeLast()
        return true
    }

    private func onEscape() {
        guard !input.isEmpty else { return }
        input = ""
        suggestions = []
        highlighted = -1
    }

    private func save() {
        persistFailure = nil
        let durable = session.applyMacTags(groupId: group.id, subjects: subjects,
                                           priority: priority, year: Int(yearText), month: month)
        if !durable { persistFailure = CaptureSession.tagDecisionNotDurableMessage }
    }

    /// Skip is a decision too — it must be as durable as Save, or a relaunch re-asks for a segment whose
    /// output live processing already produced.
    private func skip() {
        persistFailure = nil
        if !session.skipMacTags(groupId: group.id) {
            persistFailure = CaptureSession.tagDecisionNotDurableMessage
        }
    }
}

// MARK: - Live end-of-session rotation review

/// Process Live rotation review: a dedicated, keyboard-fast pass over every captured page shown at
/// Finish (before collection naming). Confirming regenerates the affected staged PDF/JPG with the
/// corrected rotation; images preview already-oriented.
struct LiveRotationReviewSheet: View {
    @ObservedObject var liveProc: LiveCaptureProcessor
    @State private var thumbnailSize: CGFloat = 320
    @State private var focusedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Rotation").font(.title2).fontWeight(.semibold)
                    Text("Keys: \u{2190}\u{2192} or [ ]=Rotate  \u{2191}\u{2193}=Navigate  Return=Continue")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "photo.artframe").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 60...800, step: 10)
                Image(systemName: "photo.artframe").font(.body).foregroundStyle(.secondary)
                Text("\(Int(thumbnailSize))px").font(.caption2).foregroundStyle(.secondary).frame(width: 40)
            }
            .padding(.horizontal).padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(liveProc.rotationReviewPages.indices, id: \.self) { idx in
                            LiveRotationRow(page: $liveProc.rotationReviewPages[idx],
                                            thumbnailSize: thumbnailSize,
                                            isFocused: idx == focusedIndex)
                                .id(idx)
                                .onTapGesture { focusedIndex = idx }
                        }
                    }
                    .padding()
                }
                .onChange(of: focusedIndex) { _, n in withAnimation { proxy.scrollTo(n, anchor: .center) } }
            }

            Divider()

            HStack {
                Text("\(liveProc.rotationReviewPages.count) page\(liveProc.rotationReviewPages.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { liveProc.cancelRotationReview() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") { liveProc.applyRotationReviewAndFinalize() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(minWidth: 800, idealWidth: 1200, maxWidth: .infinity, minHeight: 700, idealHeight: 1000, maxHeight: .infinity)
        .onKeyPress(.upArrow) { if focusedIndex > 0 { focusedIndex -= 1 }; return .handled }
        .onKeyPress(.downArrow) { if focusedIndex < liveProc.rotationReviewPages.count - 1 { focusedIndex += 1 }; return .handled }
        .onKeyPress(.leftArrow) { rotate(-90); return .handled }
        .onKeyPress(.rightArrow) { rotate(90); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "[")) { _ in rotate(-90); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "]")) { _ in rotate(90); return .handled }
    }

    private func rotate(_ delta: Int) {
        guard focusedIndex < liveProc.rotationReviewPages.count else { return }
        let cur = liveProc.rotationReviewPages[focusedIndex].rotationDegrees
        liveProc.rotationReviewPages[focusedIndex].rotationDegrees = (((cur + delta) % 360) + 360) % 360
    }
}

private struct LiveRotationRow: View {
    @Binding var page: LiveCaptureProcessor.RotationReviewPage
    let thumbnailSize: CGFloat
    var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            ArchiveThumbnail(url: page.sourceURL, maxSize: 1000, rotationDegrees: page.rotationDegrees)
                .frame(width: thumbnailSize, height: thumbnailSize)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 8) {
                Text(page.sourceURL.lastPathComponent)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(minWidth: 180, alignment: .leading)
                HStack(spacing: 8) {
                    Text("Rotate:").font(.caption).foregroundStyle(.secondary)
                    ForEach([0, 90, 180, 270], id: \.self) { deg in
                        Button { page.rotationDegrees = deg } label: {
                            HStack(spacing: 3) {
                                Image(systemName: page.rotationDegrees == deg ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(page.rotationDegrees == deg ? .orange : .secondary)
                                    .font(.system(size: 10))
                                Text("\(deg)°").font(.caption2)
                                    .foregroundStyle(page.rotationDegrees == deg ? .orange : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isFocused ? Color.accentColor : Color.clear, lineWidth: 2))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Live Capture adapter into the shared per-item read model (A1)

/// Maps a `LiveCaptureProcessor.SegmentStatus` (joined with its retained OCR text + provider·model) into
/// the shared `ProcessableItem`, so the Processing pane renders with the same row/list as the Files pane.
struct SegmentItem: ProcessableItem {
    let itemID: String
    let title: String
    let subtitle: String?
    let state: ItemState
    let classification: DocumentClassification?
    let rotationDegrees: Int?
    let ocrText: String?
    let errorMessage: String?
    let errorCode: String?
    let providerModel: String?
    let availableActions: [ItemAction]

    init(status s: LiveCaptureProcessor.SegmentStatus, ocrText: String?, providerModel: String?, expanded: Bool) {
        self.itemID = s.id
        self.title = "\(s.index). \(s.type.rawValue.capitalized) · \(s.pageCount)p"
        self.subtitle = nil
        let st = Self.state(for: s)
        self.state = st
        self.classification = Self.classification(for: s.type)
        self.rotationDegrees = nil
        self.ocrText = ocrText
        self.errorMessage = s.errorMessage
        self.errorCode = s.errorCode
        self.providerModel = providerModel
        self.availableActions = expanded ? Self.actions(for: st) : []
    }

    static func state(for s: LiveCaptureProcessor.SegmentStatus) -> ItemState {
        switch s.phase {
        case .ocr: return .processing(label: "OCR…")
        case .tagging: return .processing(label: "Tagging…")
        case .staged: return .succeeded
        case .succeededNoText: return .succeededNoText
        case .succeededPlaceholderImage: return .succeededPlaceholderImage
        case .failed: return .failed(s.failureKind ?? .noOutput)
        }
    }

    static func classification(for type: CaptureGroupType) -> DocumentClassification? {
        switch type {
        case .box: return .boxLabel
        case .folder: return .folderLabel
        case .document: return nil
        }
    }

    /// Actions offered per state. Reclassify is Files-only; file-as-image-only isn't offered here (§4a
    /// already files a complete image-only doc automatically as `succeededNoText`).
    static func actions(for state: ItemState) -> [ItemAction] {
        switch state {
        case .failed:
            return [.retry, .retryWithModel, .changeRotation, .viewText, .revealFiles]
        case .succeededNoText:
            return [.retry, .retryWithModel, .viewText, .revealFiles]
        case .succeededPlaceholderImage:
            // Same recovery affordances: the source photo is deliberately still in the Backup Folder, so a
            // retry (optionally after a rotate) is exactly how the operator gets the scan into the archive.
            return [.retry, .retryWithModel, .changeRotation, .viewText, .revealFiles]
        case .succeeded:
            return [.viewText, .revealFiles]
        default:
            return []
        }
    }
}

/// Read-only viewer for a segment's OCR text + any error reason (the shared `viewText` action, Live side).
private struct SegmentTextViewerSheet: View {
    let text: String?
    let errorMessage: String?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OCR Text").font(.title2).fontWeight(.semibold)
            if let text, !text.isEmpty {
                ScrollView {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            } else {
                Text("No OCR text was returned for this segment.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let errorMessage, !errorMessage.isEmpty {
                GroupBox("Error") {
                    Text(errorMessage).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
    }
}
