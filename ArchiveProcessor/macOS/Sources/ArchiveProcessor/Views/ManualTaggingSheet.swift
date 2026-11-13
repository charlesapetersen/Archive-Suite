import SwiftUI
import AppKit
import ArchiveCore

/// Sequential manual tagging — one document segment at a time. Shows all page images in the
/// segment plus editable date fields and an autocompleting subject-tag input. In `.autoDate`
/// mode the date fields are prefilled by the LLM as prefetch results arrive.
///
/// Keys (when the image strip is focused): ← / → cycle the highlighted image; Space opens a
/// Finder-Quick-Look-style large preview (Esc / Space / click closes). Return = Next segment.
struct ManualTaggingSheet: View {
    @ObservedObject var processor: OCRProcessor
    @State private var focusedImage = 0
    @State private var showPreview = false
    @FocusState private var canvasFocused: Bool

    private var count: Int { processor.manualTagSegments.count }
    private var isLast: Bool { processor.currentManualIndex >= count - 1 }
    /// W37: the current card's dates can be saved — no unreadable typed date, no invalid Sent-with value
    /// (Next/Finish refuse otherwise).
    private var currentDatesValid: Bool {
        guard processor.currentManualIndex < count else { return true }
        return processor.manualTagSegments[processor.currentManualIndex].datesAreValid
    }
    private var currentImages: [ManualTagImage] {
        guard processor.currentManualIndex < count else { return [] }
        return processor.manualTagSegments[processor.currentManualIndex].images
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Manual Tagging")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Segment \(min(processor.currentManualIndex + 1, count)) of \(count)")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                Spacer()
                Text("← → image   Space = preview")
                    .font(.caption2).foregroundStyle(.primary)
            }
            .padding()

            Divider()

            if processor.currentManualIndex < count {
                ManualTagSegmentView(
                    segment: $processor.manualTagSegments[processor.currentManualIndex],
                    focusedImage: $focusedImage
                )
                .focusable(true)
                .focused($canvasFocused)
                .onKeyPress(.leftArrow) { moveFocusedImage(-1); return .handled }
                .onKeyPress(.rightArrow) { moveFocusedImage(1); return .handled }
                .onKeyPress(.space) { showPreview.toggle(); return .handled }
                .onKeyPress(.escape) {
                    if showPreview { showPreview = false; return .handled }
                    return .ignored
                }
            } else {
                Spacer()
            }

            Divider()

            HStack {
                Button("Back") { processor.previousManualSegment() }
                    .disabled(processor.currentManualIndex == 0)
                Spacer()
                Button(isLast ? "Finish" : "Next") { processor.advanceManualSegment() }
                    .disabled(!currentDatesValid)
                    .prominentButtonStyle()
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding()
        }
        .frame(minWidth: 800, idealWidth: 1200, maxWidth: .infinity, minHeight: 700, idealHeight: 1000, maxHeight: .infinity)
        .overlay {
            if showPreview, focusedImage < currentImages.count {
                quickLookOverlay
            }
        }
        .onAppear {
            SystemTagsProvider.shared.warmUp()
            canvasFocused = true
            DispatchQueue.main.async {
                NSApp.keyWindow?.styleMask.insert(.resizable)
            }
        }
        .onChange(of: processor.currentManualIndex) { _, _ in
            focusedImage = 0
            showPreview = false   // close the preview so it can't index the previous (larger) segment
            canvasFocused = true
        }
    }

    private func moveFocusedImage(_ delta: Int) {
        let n = focusedImage + delta
        if n >= 0 && n < currentImages.count { focusedImage = n }
    }

    /// Finder-Quick-Look-style large preview of the currently highlighted image.
    private var quickLookOverlay: some View {
        let img = currentImages[focusedImage]
        return ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 8) {
                ArchiveThumbnail(url: img.url, maxSize: 3000, rotationDegrees: img.rotationDegrees)
                    .padding(24)
                Text("\(img.url.lastPathComponent)   ·   Image \(focusedImage + 1) / \(currentImages.count)   ·   Space or Esc to close")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showPreview = false; canvasFocused = true }
        .transition(.opacity)
    }
}

struct ManualTagSegmentView: View {
    @Binding var segment: ManualTagSegment
    @Binding var focusedImage: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Page images (shown in their corrected rotation; context image first)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(spacing: 12) {
                            ForEach(Array(segment.images.enumerated()), id: \.element.id) { idx, img in
                                VStack(spacing: 4) {
                                    ArchiveThumbnail(url: img.url, maxSize: 1000, rotationDegrees: img.rotationDegrees)
                                        .frame(width: 560, height: 560)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(imageBorder(img: img, focused: idx == focusedImage))
                                        .id(idx)
                                    if img.isContext {
                                        Text("Context — previous box/folder (not tagged)")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    } else {
                                        Text(img.url.lastPathComponent)
                                            .font(.caption2)
                                            .foregroundStyle(idx == focusedImage ? Color.accentColor : .primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .frame(maxWidth: 560)
                                    }
                                }
                                .onTapGesture { focusedImage = idx }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 600)
                    .onChange(of: focusedImage) { _, newValue in
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }

                // Date (W40.processor-date-field): the own date in one typed field, the covering letter's a level below.
                GroupBox("Date") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 12) {
                            TypedDateField(label: "Date", date: $segment.ownDate,
                                           unreadable: $segment.dateTextUnreadable,
                                           fallbackText: TypedDateTags.rawText(segment.dateComponents),
                                           accessibilityID: "ap.date.own")
                            Toggle("Date uncertain", isOn: $segment.dateUncertain)
                                .padding(.top, 14)
                            if segment.dateLoading {
                                ProgressView().scaleEffect(0.6)
                                Text("estimating…").font(.caption2).foregroundStyle(.primary)
                                    .padding(.top, 14)
                            }
                            Spacer()
                        }
                        // W37.dual-date — the covering letter's date, for an enclosure with its own date.
                        SentWithDateSection(
                            sentWith: $segment.sentWith, uncertain: $segment.sentWithUncertain,
                            unreadable: $segment.sentWithTextUnreadable,
                            emptyMeaning: segment.enclosureOfSegmentIndex != nil
                                ? "Empty: the covering letter's own date is used (none if it is undated)."
                                : "Leave it empty for an item that was not enclosed with a letter.",
                            startsExpanded: segment.enclosureOfSegmentIndex != nil
                        ) {
                            if let cover = segment.enclosureCoverName, segment.enclosureOfSegmentIndex != nil {
                                HStack(spacing: 8) {
                                    Image(systemName: "paperclip")
                                    Text("Proposed: enclosure sent with the letter starting “\(cover)”.")
                                        .font(.caption)
                                    Button("Not an enclosure") {
                                        segment.enclosureOfSegmentIndex = nil
                                        segment.enclosureCoverName = nil
                                    }
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .id(segment.id)   // a new segment seeds its own fields
                }

                // Subjects
                GroupBox("Subject tags") {
                    VStack(alignment: .leading, spacing: 4) {
                        TagInputField(tags: $segment.subjectTags, placeholder: "Type a subject and press Return…")
                        Text("Suggestions come from Finder tags already in use on your Mac.")
                            .font(.caption2)
                            .foregroundStyle(.primary)
                    }
                    .padding(6)
                }

                GroupBox("Quality") {
                    QualityPicker(quality: $segment.quality)
                        .padding(6)
                }
            }
            .padding()
        }
    }

    private func imageBorder(img: ManualTagImage, focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(
                focused ? Color.accentColor : (img.isContext ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.2)),
                style: StrokeStyle(lineWidth: focused ? 3 : (img.isContext ? 2 : 1), dash: img.isContext && !focused ? [6] : [])
            )
    }
}

/// The suite-wide human Quality control. `0` is intentionally shown as Unrated and emits no Finder
/// token; values 1...3 become Q1...Q3 through `GeneratedTags.allTags`.
struct QualityPicker: View {
    @Binding var quality: Int

    var body: some View {
        Picker("Quality", selection: $quality) {
            Text("0 — Unrated").tag(0)
            ForEach(1...3, id: \.self) { value in
                Text("\(value) — Q\(value)").tag(value)
            }
        }
    }
}
