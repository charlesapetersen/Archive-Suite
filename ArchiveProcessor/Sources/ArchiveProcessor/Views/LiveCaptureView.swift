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
    @AppStorage("liveProcessingMode") private var liveProcessingMode: String = "stage"

    var body: some View {
        HSplitView {
            controlPanel
                .frame(minWidth: 300, maxWidth: 360)
                .padding()
            capturePanel
                .padding()
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
        .sheet(item: Binding(get: { session.pendingTagGroup }, set: { _ in })) { group in
            SegmentTagCard(group: group, session: session)
        }
        .sheet(isPresented: $liveProc.showFinalizeSheet) {
            CollectionFinalizeSheet(liveProc: liveProc)
        }
        .sheet(isPresented: $liveProc.showRotationReview) {
            LiveRotationReviewSheet(liveProc: liveProc)
        }
    }

    // MARK: Left — connection / pairing

    private var controlPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Live Capture")
                    .font(.title).fontWeight(.bold)

                GroupBox("Connection") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Circle().fill(session.serverRunning ? .green : .secondary).frame(width: 8, height: 8)
                            Text(session.serverRunning ? "Listening" : "Stopped").font(.callout)
                            Spacer()
                            if session.serverRunning {
                                Button("Stop") { session.stop() }
                            } else {
                                Button("Start") { session.start() }
                                    .buttonStyle(.borderedProminent)
                            }
                        }
                        Text(session.statusMessage)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                }

                GroupBox("Processing") {
                    VStack(alignment: .leading, spacing: 8) {
                        let live = liveProcessingMode == "live"
                        Label(live ? "Process live" : "Stage for later",
                              systemImage: live ? "bolt.fill" : "tray.and.arrow.down")
                            .font(.callout).fontWeight(.medium)
                        Text(live ? "Each segment is OCR'd & tagged as you capture; finish the session to name collections."
                                  : "Captures collect here; use Process to send them to the Files tab.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Change in Settings (⌘,).").font(.caption2).foregroundStyle(.tertiary)

                        if live, let cfg = session.config {
                            Text(cfg.summary).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if live, !liveProc.statuses.isEmpty {
                            Divider()
                            let done = liveProc.statuses.filter { $0.phase == .staged }.count
                            Text("\(done)/\(liveProc.statuses.count) segments processed")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(liveProc.statuses) { s in
                                        HStack(spacing: 6) {
                                            Circle().fill(phaseColor(s.phase)).frame(width: 6, height: 6)
                                            Text("\(s.index). \(s.type.rawValue.capitalized) · \(s.pageCount)p")
                                                .font(.caption2)
                                            Spacer()
                                            Text(s.phase.rawValue).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .frame(maxHeight: 150)
                            if !liveProc.failedGroupIds.isEmpty {
                                Button("Retry \(liveProc.failedGroupIds.count) failed OCR") { liveProc.retryFailed() }
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                    }
                    .padding(6)
                }

                if session.serverRunning, session.paired {
                    GroupBox("Phone") {
                        HStack(spacing: 6) {
                            Image(systemName: "iphone.gen3").foregroundStyle(.green)
                            Text(session.connectedDeviceName.map { "Paired · \($0)" } ?? "Paired")
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
                            Text("Scan in the Archive Capture app").font(.caption).foregroundStyle(.secondary)
                            if let ip = Self.primaryIPv4() {
                                Text("\(ip):\(session.listenPort)")
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(6)
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    /// JSON pairing payload encoded in the QR: host / port / token / name.
    private var pairingPayload: String? {
        guard session.serverRunning, let ip = Self.primaryIPv4() else { return nil }
        let dict: [String: Any] = [
            "host": ip,
            "port": Int(session.listenPort),
            "token": session.token,
            "name": Host.current().localizedName ?? "Mac"
        ]
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
                Spacer()
                if !session.photos.isEmpty {
                    Button("Clear") { session.clear(); liveProc.clearFinalizeSummary() }
                    if liveProcessingMode != "live" {
                        Button("Process \(session.photos.count) →") { stageForProcessing() }
                            .buttonStyle(.borderedProminent)
                            .disabled(processor.isProcessing)
                    } else if !liveProc.staged.isEmpty {
                        Button("Finish session (\(liveProc.staged.count)) →") { liveProc.finishSession() }
                            .buttonStyle(.borderedProminent)
                            .disabled(liveProc.isFinalizing)
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
                        Text(session.serverRunning ? "Waiting for photos…\nShoot on the phone; they'll appear here grouped."
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

    private func phaseColor(_ phase: LiveCaptureProcessor.SegmentStatus.Phase) -> Color {
        switch phase {
        case .ocr: return .orange
        case .tagging: return .blue
        case .staged: return .green
        case .failed: return .red
        }
    }

    // MARK: Handoff

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
            address = String(cString: host)
            if name == "en0" { break }   // prefer Wi-Fi/primary
        }
        return address
    }
}

/// Auto-advancing tag card for one completed document segment during Live Capture. Subjects are the
/// piece the phone doesn't capture; year/month/priority default to the phone's values and are editable.
/// Built for keyboard speed: type subjects, ↑/↓ to pick a suggestion, ⇥ to autocomplete, ⏎ to add
/// (⏎ on an empty field saves), ⌫ on an empty field deletes the previous tag, esc skips.
private struct SegmentTagCard: View {
    let group: CaptureGroup
    @ObservedObject var session: CaptureSession

    @State private var subjects: [String] = []
    @State private var input: String = ""
    @State private var suggestions: [String] = []
    @State private var highlighted: Int = -1     // -1 = typed text is the candidate; ≥0 = a suggestion
    @State private var yearText: String = ""
    @State private var month: Int? = nil
    @State private var priority: String? = nil

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

            Text("↑↓ pick · ⇥ complete · ⏎ add (⏎ on empty saves) · ⌫ delete last · esc skip")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Button("Skip") { session.skipMacTags(groupId: group.id) }
                Spacer()
                Button("Save ▸") { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: input) { _, _ in recompute() }
        .onAppear {
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
            Text("Subjects").font(.callout).fontWeight(.medium)
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
        if input.isEmpty { session.skipMacTags(groupId: group.id) }
        else { input = ""; suggestions = []; highlighted = -1 }
    }

    private func save() {
        session.applyMacTags(groupId: group.id, subjects: subjects,
                             priority: priority, year: Int(yearText), month: month)
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
