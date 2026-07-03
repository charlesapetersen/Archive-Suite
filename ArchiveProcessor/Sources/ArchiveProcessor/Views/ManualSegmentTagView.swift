import SwiftUI
import AppKit

/// Progressive manual segmentation + tagging (human / autoDateManualSeg modes), modeled on the
/// Live Capture tag card. The user walks the photos in order, reviews rotation and box/folder
/// identifications, marks where each document segment ends, and tags it — as a segment is tagged
/// its pages drop out of the viewer. Box/folder photos stay as markers. When only boxes/folders
/// remain, Finish resumes the pipeline. Keyboard-first.
///
/// Keys (image canvas focused):
///   ← / →   previous / next photo
///   R       rotate 90°           X   remove / restore this photo
///   B / F / D   mark Box / Folder / Document
///   Space   Quick Look preview   + / − / 0   zoom (drag or scroll to pan when zoomed)
///   ⏎       end the current segment here & tag it
struct ManualSegmentTagView: View {
    @ObservedObject var processor: OCRProcessor
    @State private var zoom: CGFloat = 1
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
            DispatchQueue.main.async { NSApp.keyWindow?.styleMask.insert(.resizable) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Segment & Tag").font(.title2).fontWeight(.semibold)
                Text(progressLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text("← → photo   ⏎ end & tag   R rotate   B/F/D box/folder/doc   X remove   Space preview")
                    .font(.caption2).foregroundStyle(.tertiary)
                Button("Finish ▸") { processor.confirmManualSegTag() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!processor.manualSegCanFinish)
                    .help(processor.manualSegCanFinish
                          ? "Apply all tags and continue."
                          : "Tag or remove every document first (\(remainingDocs) left).")
            }
        }
        .padding()
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
        .onKeyPress(characters: CharacterSet(charactersIn: "rR")) { _ in processor.manualSegRotate(at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "xX")) { _ in processor.manualSegToggleRemoved(at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in processor.manualSegSetKind(.box, at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "fF")) { _ in processor.manualSegSetKind(.folder, at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "dD")) { _ in processor.manualSegSetKind(.document, at: focus); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in zoom = min(8, zoom * 1.25); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "-_")) { _ in zoom = max(0.5, zoom / 1.25); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in zoom = 1; return .handled }
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

                Button { processor.manualSegRotate(at: focus) } label: { Image(systemName: "rotate.right") }
                    .help("Rotate 90° (R)")
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

    private func resetZoom() { zoom = 1 }
}

// MARK: - Tag card (keyboard-driven; fixed width so it never resizes the viewer)

/// The per-segment tag card, modeled on the Live Capture `SegmentTagCard`. Bound to the
/// processor's `manualSegDraftTags`; Save commits the pending segment, Back returns to browsing.
private struct ManualSegTagCard: View {
    @ObservedObject var processor: OCRProcessor

    @State private var input = ""
    @State private var suggestions: [String] = []
    @State private var highlighted = -1

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

            subjectsSection

            HStack(alignment: .bottom, spacing: 12) {
                dateField("Year", text: $processor.manualSegDraftTags.year, width: 66, prompt: "1968")
                dateField("Month", text: $processor.manualSegDraftTags.month, width: 118, prompt: "03 March")
                dateField("Day", text: $processor.manualSegDraftTags.day, width: 78, prompt: "Day 15")
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

    private func dateField(_ label: String, text: Binding<String>, width: CGFloat, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(width: width)
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
