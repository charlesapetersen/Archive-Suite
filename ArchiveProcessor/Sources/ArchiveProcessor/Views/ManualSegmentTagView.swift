import SwiftUI
import AppKit

/// Progressive manual segmentation + tagging (human / autoDateManualSeg modes). The user walks the
/// photos in order, reviews box/folder identifications, marks where each document segment ends, and
/// tags it — as a segment is tagged its pages drop out of the viewer. Box/folder photos stay as
/// markers. When only boxes/folders remain, Finish resumes the pipeline. Keyboard-first. Rotation is
/// a separate, earlier step (the "Review rotation" pass); images here display already-oriented.
///
/// Keys (image canvas focused):
///   ← / →   previous / next photo    X   remove / restore this photo
///   B / F / D   mark Box / Folder / Document
///   Space   Quick Look preview   + / − / 0 or ⌘↑ / ⌘↓   zoom (drag or scroll to pan when zoomed)
///   ⏎       end the current segment here & tag it
struct ManualSegmentTagView: View {
    @ObservedObject var processor: OCRProcessor
    // Open (and re-show each photo) zoomed to 150% with the top edge anchored, so the first lines are
    // readable immediately; ZoomableImageView top-anchors when zoom > 1. Press 0 to fit the whole page.
    @State private var zoom: CGFloat = 1.5
    @State private var showPreview = false
    @FocusState private var canvasFocused: Bool

    private var images: [ManualSegImage] { processor.manualSegImages }
    private var count: Int { images.count }
    private var focus: Int { min(max(processor.manualSegFocus, 0), max(0, count - 1)) }
    private var focusImage: ManualSegImage? { focus < count ? images[focus] : nil }
    private var pendingRange: ClosedRange<Int>? { processor.manualSegPendingRange }
    private var tagging: Bool { processor.manualSegTaggingRange != nil }

    // Progress counters.
    private var taggedDocs: Int { processor.manualSegCompleted.count }
    private var remainingDocs: Int { processor.manualSegRemainingDocCount }
    private var boxCount: Int { images.indices.filter { images[$0].kind == .box && !processor.manualSegRemoved.contains($0) }.count }
    private var folderCount: Int { images.indices.filter { images[$0].kind == .folder && !processor.manualSegRemoved.contains($0) }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            filmstrip
            Divider()
            controls
        }
        .frame(minWidth: 900, idealWidth: 1500, maxWidth: .infinity, minHeight: 700, idealHeight: 1100, maxHeight: .infinity)
        .overlay {
            if showPreview, let img = focusImage {
                quickLookOverlay(img)
            }
        }
        .overlay(alignment: .trailing) {
            if tagging {
                ManualSegTagCard(processor: processor)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .padding(.trailing, 24)
            }
        }
        .onAppear {
            SystemTagsProvider.shared.warmUp()
            canvasFocused = true
        }
    }

    // MARK: Header

    // Compact single-row header so the image gets as much vertical space as possible.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Segment & Tag").font(.headline)
            Text(progressLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 12)
            Text("← → photo · ⏎ end & tag · B/F/D · X remove · Space preview")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).layoutPriority(-1)
            Button("Finish ▸") { processor.confirmManualSegTag() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!processor.manualSegCanFinish)
                .help(processor.manualSegCanFinish
                      ? "Apply all tags and continue."
                      : "Tag or remove every document first (\(remainingDocs) left).")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var progressLine: String {
        var parts = ["\(taggedDocs) document\(taggedDocs == 1 ? "" : "s") tagged"]
        if remainingDocs > 0 { parts.append("\(remainingDocs) remaining") }
        if boxCount > 0 { parts.append("\(boxCount) box\(boxCount == 1 ? "" : "es")") }
        if folderCount > 0 { parts.append("\(folderCount) folder\(folderCount == 1 ? "" : "s")") }
        return parts.joined(separator: "   ·   ")
    }

    // MARK: Canvas (focusable — receives navigation keys)

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            if let img = focusImage, !processor.manualSegConsumed.contains(focus) {
                ZoomableImageView(url: img.url, rotationDegrees: img.rotationDegrees, zoom: $zoom)
                statusBadge(img).padding(10)
            } else {
                ZStack {
                    Color(nsColor: .textBackgroundColor).opacity(0.4)
                    VStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("All documents tagged — click Finish ▸").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($canvasFocused)
        .onTapGesture { canvasFocused = true }
        .onKeyPress(.leftArrow) { processor.manualSegAdvanceFocus(-1); resetZoom(); return .handled }
        .onKeyPress(.rightArrow) { processor.manualSegAdvanceFocus(1); resetZoom(); return .handled }
        .onKeyPress(.return) { processor.manualSegEndAndTag(); return .handled }
        .onKeyPress(.space) { showPreview.toggle(); return .handled }
        .onKeyPress(.escape) {
            if showPreview { showPreview = false; return .handled }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "xX")) { _ in processor.manualSegToggleRemoved(at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in processor.manualSegSetKind(.box, at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in processor.manualSegSetKind(.folder, at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "dD")) { _ in processor.manualSegSetKind(.document, at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in zoom = min(8, zoom * 1.25); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "-_")) { _ in zoom = max(1, zoom / 1.25); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in zoom = 1; return .handled }
        // ⌘↑ / ⌘↓ are alternative zoom in / out shortcuts (plain ↑/↓ are unused on this canvas).
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            zoom = press.key == .upArrow ? min(8, zoom * 1.25) : max(1, zoom / 1.25)
            return .handled
        }
    }

    /// The badge shown over the focused image describing its state.
    private func statusBadge(_ img: ManualSegImage) -> some View {
        let removed = processor.manualSegRemoved.contains(focus)
        let inPending = pendingRange?.contains(focus) ?? false
        return HStack(spacing: 6) {
            Text("Photo \(focus + 1) / \(count)")
            Divider().frame(height: 12)
            switch img.kind {
            case .box:
                Image(systemName: "shippingbox.fill"); Text("Box")
            case .folder:
                Image(systemName: "folder.fill"); Text("Folder")
            case .document:
                if removed { Image(systemName: "trash"); Text("Removed") }
                else if inPending { Image(systemName: "doc.text.fill"); Text("In current segment") }
                else { Image(systemName: "doc.text"); Text("Document") }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(badgeColor(img, removed: removed, inPending: inPending))
    }

    private func badgeColor(_ img: ManualSegImage, removed: Bool, inPending: Bool) -> Color {
        if removed { return .red }
        switch img.kind {
        case .box: return .red
        case .folder: return .purple
        case .document: return inPending ? Color.accentColor : .secondary
        }
    }

    // MARK: Filmstrip (remaining photos; pending segment highlighted)

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    ForEach(images.indices.filter { !processor.manualSegConsumed.contains($0) }, id: \.self) { i in
                        filmstripCell(i).id(i)
                    }
                    if remainingDocs == 0 {
                        Text("All documents tagged — click Finish ▸")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(height: 116)
            .onChange(of: processor.manualSegFocus) { _, f in
                withAnimation { proxy.scrollTo(f, anchor: .center) }
            }
        }
    }

    private func filmstripCell(_ i: Int) -> some View {
        let img = images[i]
        let isFocus = i == focus
        let inPending = pendingRange?.contains(i) ?? false
        let removed = processor.manualSegRemoved.contains(i)
        let border: Color = isFocus ? .accentColor : (inPending ? Color.accentColor.opacity(0.5) : .secondary.opacity(0.25))
        return VStack(spacing: 2) {
            ArchiveThumbnail(url: img.url, maxSize: 200, rotationDegrees: img.rotationDegrees)
                .frame(width: 74, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(border, lineWidth: isFocus ? 3 : 1.5))
                .overlay(alignment: .topLeading) { kindGlyph(img, removed: removed).padding(3) }
                .opacity(removed ? 0.4 : 1)
            Text("\(i + 1)").font(.caption2).foregroundStyle(isFocus ? Color.accentColor : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { processor.manualSegFocus = i; resetZoom(); canvasFocused = true }
    }

    @ViewBuilder
    private func kindGlyph(_ img: ManualSegImage, removed: Bool) -> some View {
        if removed {
            glyph("trash", .red)
        } else if img.kind == .box {
            glyph("shippingbox.fill", .red)
        } else if img.kind == .folder {
            glyph("folder.fill", .purple)
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.caption2).foregroundStyle(.white)
            .padding(3).background(Circle().fill(color))
    }

    // MARK: Bottom controls

    private var controls: some View {
        HStack(spacing: 12) {
            if let img = focusImage {
                Picker("", selection: kindBinding(img)) {
                    Label("Document", systemImage: "doc.text").tag(ManualPhotoKind.document)
                    Label("Box", systemImage: "shippingbox").tag(ManualPhotoKind.box)
                    Label("Folder", systemImage: "folder").tag(ManualPhotoKind.folder)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                .disabled(processor.manualSegConsumed.contains(focus))

                Button { processor.manualSegToggleRemoved(at: focus) } label: {
                    Image(systemName: processor.manualSegRemoved.contains(focus) ? "arrow.uturn.backward" : "trash")
                }
                .help(processor.manualSegRemoved.contains(focus) ? "Restore (X)" : "Remove (X)")
                .disabled(processor.manualSegConsumed.contains(focus))
            }
            Spacer()
            if let range = pendingRange {
                let pages = range.count
                Text("Current segment: \(pages) page\(pages == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                Button("End segment & tag ▸") { processor.manualSegEndAndTag() }
                    .buttonStyle(.borderedProminent)
                    .disabled(tagging)
            }
        }
        .padding()
    }

    private func kindBinding(_ img: ManualSegImage) -> Binding<ManualPhotoKind> {
        Binding(get: { img.kind }, set: { processor.manualSegSetKind($0, at: focus) })
    }

    // MARK: Quick Look preview (Space)

    private func quickLookOverlay(_ img: ManualSegImage) -> some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 8) {
                ArchiveThumbnail(url: img.url, maxSize: 3000, rotationDegrees: img.rotationDegrees)
                    .padding(24)
                Text("\(img.url.lastPathComponent)   ·   Photo \(focus + 1) / \(count)   ·   Space or Esc to close")
                    .font(.caption).foregroundStyle(.white.opacity(0.8)).padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showPreview = false; canvasFocused = true }
        .transition(.opacity)
    }

    private func resetZoom() { zoom = 1.5 }
}

// MARK: - Tag card (keyboard-driven; fixed width so it never resizes the viewer)

/// The per-segment tag card, modeled on the Live Capture `SegmentTagCard`. Bound to the
/// processor's `manualSegDraftTags`; Save commits the pending segment, Back returns to browsing.
private struct ManualSegTagCard: View {
    @ObservedObject var processor: OCRProcessor

    @State private var input = ""
    @State private var suggestions: [String] = []
    @State private var highlighted = -1
    @FocusState private var yearFocused: Bool

    private var subjects: Binding<[String]> {
        Binding(get: { processor.manualSegDraftTags.subjectTags },
                set: { processor.manualSegDraftTags.subjectTags = $0 })
    }
    private var pageCount: Int { processor.manualSegTaggingRange?.count ?? 0 }
    private var pageIndices: [Int] { processor.manualSegTaggingRange.map { Array($0) } ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tag this segment").font(.title2).fontWeight(.semibold)
            Text("\(pageCount) page\(pageCount == 1 ? "" : "s"). Subjects become archive tags; a trailing “Unread” tag is added automatically.")
                .font(.caption).foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(pageIndices, id: \.self) { i in
                        if i < processor.manualSegImages.count {
                            let img = processor.manualSegImages[i]
                            ArchiveThumbnail(url: img.url, maxSize: 240, rotationDegrees: img.rotationDegrees)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                        }
                    }
                }
            }

            // Date first — the user reviews/enters the date (Year is focused on open) before subjects.
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Year").font(.caption2).foregroundStyle(.secondary)
                    TextField("", text: $processor.manualSegDraftTags.year)
                        .textFieldStyle(.roundedBorder).frame(width: 66)
                        .focused($yearFocused)
                }
                MonthField(month: $processor.manualSegDraftTags.month)
                DayField(day: $processor.manualSegDraftTags.day)
            }
            Toggle("Date uncertain", isOn: $processor.manualSegDraftTags.dateUncertain)
            if processor.manualSegAutoDate {
                HStack(spacing: 6) {
                    if processor.manualSegDateFetching {
                        ProgressView().scaleEffect(0.6)
                        Text("fetching date…").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Text("date auto-filled — edit if needed").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }

            subjectsSection

            Text("↑↓ pick · ⇥ complete · ⏎ add (⏎ on empty saves) · ⌫ delete last · esc back")
                .font(.caption2).foregroundStyle(.tertiary)

            HStack {
                Button("◂ Back") { processor.manualSegCancelTagging() }
                Spacer()
                Button("Save ▸") { processor.manualSegCommitPendingSegment() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.25)))
        .shadow(radius: 20)
        .padding(.vertical, 24)
        .onAppear { yearFocused = true }   // date-first: start in the Year field, not Subjects
        .onChange(of: input) { _, _ in recompute() }
        .task(id: processor.manualSegTaggingRange) {
            await processor.fetchManualSegDate(forIndices: pageIndices)
        }
    }

    private var subjectsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subjects").font(.callout).fontWeight(.medium)
            FlowLayout(spacing: 6) {
                ForEach(subjects.wrappedValue, id: \.self) { tag in
                    TagChip(text: tag) { subjects.wrappedValue.removeAll { $0 == tag } }
                }
                KeyboardTokenField(
                    text: $input,
                    placeholder: subjects.wrappedValue.isEmpty ? "Add subject…" : "",
                    onMoveUp: { moveHighlight(-1) },
                    onMoveDown: { moveHighlight(1) },
                    onTab: { onTab() },
                    onReturn: { onReturn() },
                    onDeleteWhenEmpty: { deletePrevious() },
                    onEscape: { onEscape() },
                    focusOnAppear: false
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
                            if idx == highlighted { Text("⏎").font(.caption2).foregroundStyle(.secondary) }
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

    // MARK: Keyboard actions (mirrors Live Capture SegmentTagCard)

    private func recompute() {
        let p = input.trimmingCharacters(in: .whitespaces)
        suggestions = p.isEmpty ? [] : SystemTagsProvider.shared.suggestions(prefix: input, excluding: subjects.wrappedValue, limit: 6)
        highlighted = -1
    }

    private func moveHighlight(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        if highlighted < 0 { highlighted = delta > 0 ? 0 : suggestions.count - 1 }
        else { highlighted = (highlighted + delta + suggestions.count) % suggestions.count }
    }

    private func commit(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespaces)
        input = ""; suggestions = []; highlighted = -1
        guard !t.isEmpty, !subjects.wrappedValue.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        subjects.wrappedValue.append(t)
        SystemTagsProvider.shared.register([t])
    }

    private func returnCandidate() -> String? {
        if highlighted >= 0, highlighted < suggestions.count { return suggestions[highlighted] }
        let t = input.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func tabCandidate() -> String? {
        if highlighted >= 0, highlighted < suggestions.count { return suggestions[highlighted] }
        if let first = suggestions.first { return first }
        let t = input.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    private func onReturn() -> Bool {
        if let c = returnCandidate() { commit(c); return true }
        processor.manualSegCommitPendingSegment(); return true   // empty field → save & advance
    }

    private func onTab() -> Bool {
        if let c = tabCandidate() { commit(c); return true }
        return false
    }

    private func deletePrevious() -> Bool {
        guard !subjects.wrappedValue.isEmpty else { return false }
        subjects.wrappedValue.removeLast()
        return true
    }

    private func onEscape() {
        if input.isEmpty { processor.manualSegCancelTagging() }
        else { input = ""; suggestions = []; highlighted = -1 }
    }
}

// MARK: - Month field (autocomplete; stores the canonical "MM Month" tag)

/// Month entry with autocomplete: type a month name (or prefix) or a number 1–12. The stored value
/// is always the canonical tag form, e.g. "01 January". Empty stays blank (no gray placeholder).
private struct MonthField: View {
    @Binding var month: String
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let names = ["January", "February", "March", "April", "May", "June",
                                "July", "August", "September", "October", "November", "December"]

    /// Months matching the current input — by leading number (1–12) or case-insensitive name prefix.
    private var matches: [(num: Int, name: String)] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        if let n = Int(q) { return (1...12).contains(n) ? [(n, Self.names[n - 1])] : [] }
        return Self.names.enumerated()
            .filter { $0.element.lowercased().hasPrefix(q) }
            .map { (num: $0.offset + 1, name: $0.element) }
    }

    private func canonical(_ num: Int, _ name: String) -> String { String(format: "%02d %@", num, name) }

    private func accept(_ m: (num: Int, name: String)) {
        month = canonical(m.num, m.name)
        text = month
        focused = false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Month").font(.caption2).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 118)
                .focused($focused)
                .onSubmit { if let first = matches.first { accept(first) } }
                .onChange(of: text) { _, v in
                    // Resolve the model live so a "type then Save" (no blur) still commits the canonical
                    // month. Ambiguous input (e.g. "j") waits for a pick / Return / blur.
                    let q = v.trimmingCharacters(in: .whitespaces)
                    if q.isEmpty { month = "" }
                    else if matches.count == 1 { month = canonical(matches[0].num, matches[0].name) }
                }
                .onChange(of: focused) { _, isFocused in
                    guard !isFocused else { return }
                    // Finalize on blur: resolve to a canonical month, clear if empty, else revert.
                    if let first = matches.first { month = canonical(first.num, first.name); text = month }
                    else if text.trimmingCharacters(in: .whitespaces).isEmpty { month = ""; text = "" }
                    else { text = month }
                }
                .overlay(alignment: .topLeading) {
                    if focused, text != month, !matches.isEmpty {
                        suggestionList.offset(y: 26)
                    }
                }
        }
        .onAppear { text = month }
        .onChange(of: month) { _, m in if !focused { text = m } }
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches.prefix(6), id: \.num) { m in
                Text(canonical(m.num, m.name))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { accept(m) }
            }
        }
        .frame(width: 130)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        .shadow(radius: 4)
        .zIndex(1)
    }
}

// MARK: - Day field (digits only; stores the "Day N" tag)

/// Day entry that accepts only digits, stored as the canonical tag form "Day 15". Empty stays blank.
private struct DayField: View {
    @Binding var day: String
    @State private var digits = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Day").font(.caption2).foregroundStyle(.secondary)
            TextField("", text: $digits)
                .textFieldStyle(.roundedBorder).frame(width: 78)
                .onChange(of: digits) { _, v in
                    let filtered = v.filter(\.isNumber)
                    if filtered != v { digits = filtered; return }   // strip non-digits (retriggers)
                    day = filtered.isEmpty ? "" : "Day \(filtered)"
                }
        }
        .onAppear { digits = day.filter(\.isNumber) }
        .onChange(of: day) { _, d in
            let filtered = d.filter(\.isNumber)
            if filtered != digits { digits = filtered }   // sync when auto-filled externally
        }
    }
}

// MARK: - Review window presentation (rotation/segmentation review + Segment & Tag)

extension View {
    /// Present `content` in a real, standalone, MOVABLE + resizable window that fills the visible
    /// screen — NOT a SwiftUI `.sheet` (sheets are anchored/centered by AppKit and can't be moved,
    /// and detaching one fights SwiftUI, causing a flash + re-centering). The window is created when
    /// `isPresented` becomes true and closed when it becomes false (driven by the dialog's own
    /// Confirm/Finish actions). No close/minimize button, so it can't be dismissed without resuming
    /// the review's continuation.
    func reviewWindow<C: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> C) -> some View {
        background(ReviewWindowPresenter(isPresented: isPresented, content: content))
    }
}

private struct ReviewWindowPresenter<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder var content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.sync(isPresented: isPresented, content: content)
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.closeWindow() }

    final class Coordinator {
        private var window: NSWindow?

        func sync(isPresented: Bool, content: () -> Content) {
            if isPresented {
                guard window == nil else { return }
                let hosting = NSHostingController(rootView: content())
                let w = NSWindow(contentViewController: hosting)
                w.styleMask = [.titled, .resizable]   // titled = draggable title bar; no close/minimize
                w.title = "Archive Processor"
                w.isReleasedWhenClosed = false
                if let visible = (NSApp.mainWindow?.screen ?? NSScreen.main)?.visibleFrame {
                    w.setFrame(visible, display: true)   // fill the visible screen, fully on-screen
                }
                w.makeKeyAndOrderFront(nil)
                window = w
            } else {
                closeWindow()
            }
        }

        func closeWindow() {
            window?.orderOut(nil)
            window?.close()
            window = nil
        }
    }
}
