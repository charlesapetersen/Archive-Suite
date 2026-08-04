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

    // A1 — shared Processing-list state: which segment is expanded.
    @State private var expandedSegmentID: String?

    // W3.cap-r3-fu9 — the two per-item action sheets' targets are NOT `@State` here: they live on
    // `liveProc`, because the finish flow has to be able to see that one of them is up before it raises the
    // rotation review over it. The rationale (and the three ways SwiftUI could mishandle the concurrent
    // presentation) is at `LiveCaptureProcessor.modelChoiceTarget`. Keeping no view-local copy is the point
    // — it makes the wiring compile-enforced instead of something a later edit can quietly bypass.

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
        //
        // W3.cap-r3-fu10 — THIS SCRIM IS MEANT TO BLOCK INPUT. It shipped without saying so: `Color` is
        // hit-testable and there was no `.allowsHitTesting(false)`, so it blocked as a side effect and the
        // next reader could not tell an omission from a choice. The item asked for the INTENT to be decided
        // and written down, so read the next paragraph as a decision (normative) and the one after it as the
        // limits of what has actually been observed.
        //
        // DECIDED: frozen, not live, on three grounds. (1) This overlay stands in for the sheet that is not
        // up yet — the comment above says so — and a sheet is modal, so freezing is what makes the whole
        // `isFinalizing` window behave uniformly instead of splitting into a modal half and a live half.
        // (2) Every MUTATING affordance under it is a hazard in this window: retry re-buys the OCR
        // (`W3.cap-r3-fu7`), Clear Trashes the sources the detached write is still reading
        // (`W3.cap-r3-fu11`), removing a photo strands a placeholder page (`W3.cap-r3-fu3`), and Finish is
        // already `.disabled`. Three of those four now ALSO refuse at the model layer — `retryFailed`,
        // `clearSession` and `finalize` — which is what the scrim being pointer-only makes necessary rather
        // than redundant; `removePhoto` (`W3.cap-r3-fu3`) is the one still relying on this overlay alone. ⚠️ Not "nothing under it is worth reaching", which an earlier draft claimed
        // and the adversarial pass refuted: `SegmentItem.actions(for:finalizing:)` deliberately KEEPS
        // `.viewText`/`.revealFiles` while finalizing, and driver check 7 asserts it, so freezing takes two
        // read-only affordances with it. That is accepted collateral, not an oversight — the window is short,
        // the actions lose nothing by waiting, and passing clicks through to reach them would re-expose all
        // four hazards above. It does mean check 7's preservation is, for the pointer, a statement about
        // after the window rather than during it. (3) It is not a lock-out: the mode Picker is a sibling in
        // `ContentView.mainContent`'s VStack — outside this view, so outside the frame this overlay is sized
        // to, and `.ignoresSafeArea()` reclaims safe-area INSETS rather than a sibling's layout space. So the
        // operator can still leave the tab.
        //
        // NOT YET OBSERVED, and deliberately separated from the decision above. That today's code ACHIEVES
        // the freeze is a code-read inference, not a measurement: a `Color` is hit-testable, so an overlay of
        // one should eat the clicks. The specific reason to keep the doubt is that this overlay sits over an
        // **`HSplitView`**, which is AppKit-backed (`NSSplitView`) — overlaying bridged AppKit content is the
        // case where the SwiftUI hit-test story is least certain, and the split DIVIDER especially may not be
        // covered at all. That is the thing for `W21.vmgui-d` to look at, not the general platitude.
        //
        // WHAT A SCRIM DOES NOT BUY EVEN IF IT WORKS, which is why the model-layer guards stay. It stops the
        // POINTER and nothing else. Three routes go straight through it: (a) a presented sheet floats ABOVE
        // the overlay — the predicate does not mention `modelChoiceTarget`, so the model sheet is up with the
        // scrim uselessly behind it; (b) keyboard focus, since hit testing is not the focus ring — with
        // macOS's "Keyboard navigation" setting on (System Settings → Keyboard; OFF by default, and note it
        // is a different feature from the Accessibility one named "Full Keyboard Access"), ⇥+Space still
        // reaches a control behind an overlay; (c) accessibility clients, since there is no
        // `.accessibilityAddTraits(.isModal)` here — VoiceOver can activate what the pointer cannot.
        // ⚠️ (b) and (c) are REASONED, not measured, and are flagged as such rather than asserted, since
        // inferring reachability without observing it is the exact error this item was filed to correct.
        // `.disabled` covers (b) and (c) as well as (a); this modifier covers none of them. Neither layer
        // subsumes the other. Closing (b)/(c) at the overlay — making the window modal to focus and AX and
        // not only to the pointer — is filed as `W3.cap-r3-fu10-fu1`, because the obvious one-liners interact
        // with the VM lane's own test (an `.isModal` container can hide the very buttons that test needs to
        // find) and that is a decision to take with the lane in hand.
        .overlay {
            if liveProc.isFinishingScrimUp {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.large)
                        Text("Finishing — processing segments…").font(.callout).foregroundStyle(.secondary)
                            // A stable hook for the Processor's future VM GUI lane (`W21.vmgui-d`): wait on
                            // this, then assert a panel button behind the scrim is NOT `isHittable`. That is
                            // the one observation that can confirm the paragraph above; a headless driver
                            // cannot see hit-testing at all.
                            .accessibilityIdentifier("live.finishing-throbber")
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                // The decision, in code rather than only in the comment: the whole overlay is one hit target.
                // Same shape the app already uses to absorb clicks deliberately
                // (`ManualSegmentTagView.swift:307`), minus its tap handler — there is nothing here to
                // dismiss. ⚠️ The `.frame` is load-bearing, not decoration. A first draft claimed
                // `.contentShape` alone would survive someone later removing the `Color`; it would not — the
                // `Color` is the only greedy view in this ZStack, so without it the stack collapses to the
                // padded throbber card and the hit target would shrink to that card. Pinning the frame open
                // is what makes the claim true, so the blocking now survives both restyling AND removal.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
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
        .sheet(item: $liveProc.modelChoiceTarget) { target in
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
                    liveProc.modelChoiceTarget = nil
                },
                onCancel: { liveProc.modelChoiceTarget = nil })
        }
        // Per-item "view text": the retained OCR text + any error reason.
        .sheet(item: $liveProc.textViewerTarget) { target in
            SegmentTextViewerSheet(
                text: liveProc.retainedText(for: target.id),
                errorMessage: liveProc.statuses.first(where: { $0.id == target.id })?.errorMessage,
                onDismiss: { liveProc.textViewerTarget = nil })
        }
    }

    // MARK: A1 — shared Processing list (per-item actions)

    private func performSegmentAction(_ action: ItemAction, on id: String) {
        switch action {
        case .retry:
            liveProc.retryFailed(groupIds: [id])
        case .retryWithModel:
            liveProc.modelChoiceTarget = .init(groupId: id, includeRotation: false)
        case .changeRotation:
            liveProc.modelChoiceTarget = .init(groupId: id, includeRotation: true)
        case .viewText:
            liveProc.textViewerTarget = .init(id: id)
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
                    // (received photos → Trash, recoverable) and the processing-side reset drops the
                    // Processing pane's in-memory segment/staged state (also cancels any pending Finish +
                    // summary). No on-disk deletion beyond what session.clear() already does; staged
                    // _processed output stays recoverable in the backup folder (Recovery Core Directive
                    // intact).
                    //
                    // W3.cap-r3-fu11 — the two halves are ONE model call now, and it refuses while a finish
                    // is regenerating. This used to read `session.clear(); liveProc.clearSessionState()`,
                    // which is a pair a refusal could split — and the split is worse than either half: the
                    // sources go to the Trash while `staged` still lists the segments pointing at them. The
                    // load-bearing guard is inside `clearSession()`; this `.disabled` is the operator-facing
                    // half, so the affordance is visibly off rather than silently ignored. It is also the
                    // only layer covering the KEYBOARD and VoiceOver routes: `W3.cap-r3-fu10` decided the
                    // throbber's scrim freezes the panel, but a scrim stops the pointer and nothing else
                    // (`W3.cap-r3-fu10-fu1`). Matches the Finish button below, which was already gated —
                    // note the trap this came out of, since it cost one round of mis-citation: Finish is the
                    // `.disabled(… || liveProc.isFinalizing)` further down, NOT this button.
                    Button("Clear") { liveProc.clearSession() }
                        .disabled(liveProc.isFinalizing)
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
                                // W3.cap-r3-fu9-fu1 — the operator's way OUT of the wait, beside the message
                                // that explains what it is waiting for. Before this button the only exit was
                                // Clear, which Trashes every source photo of the session, and Clear is only
                                // rendered while `session.photos` is non-empty — so once the phone had drained
                                // there was no exit at all. Re-tapping Finish is not one either (`requestFinish`
                                // re-arms). See `LiveCaptureProcessor.cancelPendingFinish` for what cancelling
                                // does and does not undo: it un-arms the wait, and nothing else — no OCR is
                                // cancelled, no staged output dropped, no file touched.
                                //
                                // Rendered on exactly `pendingFinish`, which is also the model call's own
                                // guard, so the affordance and the refusal agree by construction. NOT given a
                                // `.disabled(liveProc.isFinalizing)` like Clear and Finish, and that is a
                                // decision rather than an oversight: `pendingFinish` cannot be true alongside
                                // `isFinalizing` (see `isFinishingScrimUp`'s note — `proceedToFinishIfReady`
                                // clears it on the line before `finishSession`, and `requestFinish` guards
                                // `!isFinalizing`), so this branch never draws during a regeneration and the
                                // modifier would be dead code asserting a reachability that does not exist.
                                Button("Cancel finish") { liveProc.cancelPendingFinish() }
                                    .accessibilityIdentifier("live.cancel-finish")
                                    .help("Stop waiting to finish. Nothing captured or processed is lost — the session stays open.")
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
        // W3.cap-r3-fu7 — read once for the whole list: `liveProc` is observed, so flipping `isFinalizing`
        // rebuilds these rows and the retry-family actions come and go with the regeneration window.
        let finalizing = liveProc.isFinalizing
        return liveProc.statuses.map { s in
            let expanded = (expandedSegmentID == s.id)
            return SegmentItem(status: s,
                               ocrText: liveProc.retainedText(for: s.id),
                               providerModel: expanded ? pm : nil,
                               expanded: expanded, finalizing: finalizing)
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
                        // W3.cap-r3-fu7 — the same gate the **Finish session** button already carries (`:438`),
                        // for the same window: the end-of-session rotation review regenerates segments from a
                        // detached task with this panel visible and no sheet over it, and a retry pressed there
                        // re-buys the OCR the regeneration is still writing. `retryFailed` refuses it outright;
                        // this is so the button says so instead of looking like it did nothing.
                        // ⚠️ `W3.cap-r3-fu10` decided that the throbber's scrim is MEANT to block the pointer,
                        // which narrows what this modifier is for WITHOUT making it redundant: to the mouse it
                        // is now the second of two layers, but a scrim is not a focus barrier or an AX
                        // barrier, so this `.disabled` is what keeps ⇥+Space (macOS "Keyboard navigation",
                        // off by default) and VoiceOver off the button. It also greys the button, which is how
                        // the operator learns the affordance is off rather than merely dimmed along with
                        // everything else behind the scrim.
                        // ⚠️ The item, and this comment's first draft, called `:438` "the Clear button" — it is
                        // not, and the adversarial pass caught it. **Clear (`:396`) carries no gate at all**,
                        // and in this window it is the more destructive of the two: it Trashes the sources the
                        // detached `writeSegmentFiles` is reading and empties `staged`/`retained` under the
                        // loop that is about to index them. Filed as `W3.cap-r3-fu11` — NOT fixed here, because
                        // gating a delete path is its own decision and its own Tier-2 gate.
                        .disabled(liveProc.isFinalizing)
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

    init(status s: LiveCaptureProcessor.SegmentStatus, ocrText: String?, providerModel: String?,
         expanded: Bool, finalizing: Bool) {
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
        self.availableActions = expanded ? Self.actions(for: st, finalizing: finalizing) : []
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
    ///
    /// `finalizing` is `W3.cap-r3-fu7`: while a finish is regenerating segments, every action that leads to
    /// `retryFailed` is withheld — `.retry` directly, `.retryWithModel`/`.changeRotation` through the model
    /// sheet — because pressing one in that window re-buys the segment's OCR and races the regeneration's
    /// record replace. The bulk "Retry N failed" button is gated on the same flag and `retryFailed` refuses
    /// the call outright, which is the gate that actually holds; withholding here is so the menu does not
    /// offer it. `.viewText`/`.revealFiles` are read-only and stay. Answering the item's open question: YES,
    /// the per-item menu needs the same gate as the bulk button — it reaches the same function and spends the
    /// same money, and the expanded row is on screen in exactly the window that is exposed, so gating only
    /// the bulk button would have left the money path open through the menu beside it.
    ///
    /// `W3.cap-r3-fu10` then decided that the window's throbber scrim is meant to block the pointer, so "on
    /// screen" no longer implies "clickable". That does not retire this: a scrim is not a focus or AX barrier
    /// (⇥+Space with macOS "Keyboard navigation" on, and VoiceOver, both reach straight through one), and
    /// withholding is also what stops the menu ADVERTISING a retry that `retryFailed` would refuse. See the
    /// overlay for the three-way split — and note the same decision freezes the `.viewText`/`.revealFiles`
    /// this function deliberately KEEPS, which is accepted collateral, recorded there rather than here.
    ///
    /// `finalizing` has NO default on purpose: both call sites should have to say which case they mean, so a
    /// third one cannot inherit "not finalizing" silently.
    static func actions(for state: ItemState, finalizing: Bool) -> [ItemAction] {
        switch state {
        case .failed:
            return gate([.retry, .retryWithModel, .changeRotation, .viewText, .revealFiles], finalizing)
        case .succeededNoText:
            return gate([.retry, .retryWithModel, .viewText, .revealFiles], finalizing)
        case .succeededPlaceholderImage:
            // Same recovery affordances: the source photo is deliberately still in the Backup Folder, so a
            // retry (optionally after a rotate) is exactly how the operator gets the scan into the archive.
            return gate([.retry, .retryWithModel, .changeRotation, .viewText, .revealFiles], finalizing)
        case .succeeded:
            return gate([.viewText, .revealFiles], finalizing)
        default:
            return gate([], finalizing)
        }
    }

    /// Drops the retry-family actions when a finish is mid-regeneration (`W3.cap-r3-fu7`). Expressed as a
    /// filter over the state's own list rather than a second set of per-state literals, so a retry added to
    /// one state later cannot be gated in one place and forgotten in the other. EVERY branch routes through
    /// here, including the two that currently offer no retry at all — the adversarial pass caught that
    /// exempting them made the sentence above false, since adding `.retry` to `.succeeded` later would have
    /// produced exactly the ungated retry it claims is impossible. The calls are no-ops today; that is the
    /// point.
    private static func gate(_ actions: [ItemAction], _ finalizing: Bool) -> [ItemAction] {
        guard finalizing else { return actions }
        return actions.filter { $0 != .retry && $0 != .retryWithModel && $0 != .changeRotation }
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
