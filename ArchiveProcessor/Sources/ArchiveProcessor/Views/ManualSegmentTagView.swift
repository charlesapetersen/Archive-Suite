import SwiftUI
import AppKit

/// Fully-manual segmentation + tagging (human mode). The user examines each image full-size,
/// groups consecutive images into segments (boundary toggle), and tags each segment. Fully
/// revisable: navigate freely and edit boundaries/tags at any time. Keyboard-first.
///
/// Keys (when the image canvas is focused):
///   ← / →   previous / next image
///   ↑ / ↓   previous / next segment start
///   Space   toggle whether the current image starts a new segment
///   + / - / 0   zoom in / out / reset (drag to pan)
/// Click the tag field to type; click the image (or press Esc) to return to navigation.
struct ManualSegmentTagView: View {
    @ObservedObject var processor: OCRProcessor
    @State private var zoom: CGFloat = 1
    @State private var showPreview = false
    @FocusState private var canvasFocused: Bool

    private var images: [ManualSegImage] { processor.manualSegImages }
    private var count: Int { images.count }
    private var focus: Int { min(processor.manualSegFocus, max(0, count - 1)) }
    private var startIdx: Int { processor.manualSegStartIndex(for: focus) }
    private var segEndIdx: Int { (processor.manualSegNextStart(after: startIdx) ?? count) - 1 }
    private var isBoxFolderSegment: Bool { startIdx < count && images[startIdx].isBoxOrFolder }

    private var segmentTotal: Int { processor.manualSegIsStart.prefix(count).filter { $0 }.count }
    private var segmentOrdinal: Int {
        processor.manualSegIsStart.prefix(startIdx + 1).filter { $0 }.count
    }

    private var tagBinding: Binding<SegmentTagData> {
        let s = startIdx
        return Binding(
            get: { processor.manualSegTags[s] ?? SegmentTagData() },
            set: { processor.manualSegTags[s] = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvas
            Divider()
            bottomPanel
        }
        .frame(minWidth: 900, idealWidth: 1500, maxWidth: .infinity, minHeight: 700, idealHeight: 1100, maxHeight: .infinity)
        .overlay {
            if showPreview, focus < count {
                quickLookOverlay
            }
        }
        .onAppear {
            SystemTagsProvider.shared.warmUp()
            canvasFocused = true
            DispatchQueue.main.async { NSApp.keyWindow?.styleMask.insert(.resizable) }
        }
        // Auto-date mode: fetch this segment's date from the LLM when focus lands on it.
        .task(id: startIdx) {
            if processor.manualSegAutoDate {
                await processor.fetchManualSegDate(startIndex: startIdx)
            }
        }
    }

    // MARK: Quick Look preview (Space)

    /// A large, Finder-Quick-Look-style preview of the current image, filling the window.
    /// Space or Esc (or a click) dismisses; ← / → still page through images underneath.
    private var quickLookOverlay: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 8) {
                ArchiveThumbnail(url: images[focus].url,
                                 maxSize: 3000,
                                 rotationDegrees: images[focus].rotationDegrees)
                    .padding(24)
                Text("\(images[focus].url.lastPathComponent)   ·   Image \(focus + 1) / \(count)   ·   Space or Esc to close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showPreview = false; canvasFocused = true }
        .transition(.opacity)
    }

    private var dateLoading: Bool { processor.manualSegDateLoading.contains(startIdx) }

    // MARK: Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manual Segmentation & Tagging")
                    .font(.title2).fontWeight(.semibold)
                Text("Image \(focus + 1) / \(count)   ·   Segment \(segmentOrdinal) / \(segmentTotal) (pages \(startIdx + 1)–\(segEndIdx + 1))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("← → image   ↑ ↓ segment   Space = preview   B = boundary   +/−/0 zoom")
                .font(.caption2).foregroundStyle(.tertiary)
            Button("Finish") { processor.confirmManualSegTag() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .padding()
    }

    // MARK: Canvas (focusable — receives navigation keys)

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            if focus < count {
                ZoomableImageView(url: images[focus].url,
                                  rotationDegrees: images[focus].rotationDegrees,
                                  zoom: $zoom)
            }
            // Boundary badge
            if focus < count {
                boundaryBadge
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .focusable(true)
        .focused($canvasFocused)
        .onTapGesture { canvasFocused = true }
        .onKeyPress(.leftArrow) { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate(1); return .handled }
        .onKeyPress(.upArrow) {
            if let p = processor.manualSegPreviousStart(before: focus) { setFocus(p) }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if let n = processor.manualSegNextStart(after: startIdx) { setFocus(n) }
            return .handled
        }
        // Space: Finder-style Quick Look preview (toggle). B: toggle segment boundary.
        .onKeyPress(.space) { showPreview.toggle(); return .handled }
        .onKeyPress(.escape) {
            if showPreview { showPreview = false; return .handled }
            return .ignored
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in
            processor.toggleManualBoundary(at: focus)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "+=")) { _ in zoom = min(8, zoom * 1.25); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "-_")) { _ in zoom = max(0.5, zoom / 1.25); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "0")) { _ in zoom = 1; return .handled }
    }

    private var boundaryBadge: some View {
        let img = images[focus]
        let isStart = focus < processor.manualSegIsStart.count && processor.manualSegIsStart[focus]
        return HStack(spacing: 6) {
            if img.isBoxOrFolder {
                Image(systemName: "shippingbox")
                Text("Box/Folder — own segment")
            } else if isStart {
                Image(systemName: "flag.fill")
                Text("Segment start")
            } else {
                Image(systemName: "arrow.turn.down.right")
                Text("Continues segment")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(img.isBoxOrFolder ? .orange : (isStart ? Color.accentColor : .secondary))
    }

    // MARK: Bottom panel (tagging)

    private var bottomPanel: some View {
        Group {
            if isBoxFolderSegment {
                HStack {
                    Image(systemName: "shippingbox").foregroundStyle(.orange)
                    Text("Box/Folder label — receives a color tag, not subject tags.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom, spacing: 12) {
                        dateField("Year", text: tagBinding.year, width: 70, prompt: "1968")
                        dateField("Month", text: tagBinding.month, width: 130, prompt: "03 March")
                        dateField("Day", text: tagBinding.day, width: 90, prompt: "Day 15")
                        Toggle("Date uncertain", isOn: tagBinding.dateUncertain)
                        if processor.manualSegAutoDate {
                            if dateLoading {
                                ProgressView().scaleEffect(0.6)
                                Text("fetching date…").font(.caption2).foregroundStyle(.secondary)
                            } else {
                                Text("date auto-filled — edit if needed").font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Text("Tagging segment \(segmentOrdinal) (pages \(startIdx + 1)–\(segEndIdx + 1))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    TagInputField(tags: tagBinding.subjectTags, placeholder: "Subject tags — Return to add…")
                }
                .padding()
            }
        }
    }

    private func dateField(_ label: String, text: Binding<String>, width: CGFloat, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    // MARK: Navigation

    private func navigate(_ delta: Int) {
        let n = focus + delta
        if n >= 0 && n < count { setFocus(n) }
    }
    private func setFocus(_ i: Int) {
        processor.manualSegFocus = i
        zoom = 1
        canvasFocused = true
    }
}
