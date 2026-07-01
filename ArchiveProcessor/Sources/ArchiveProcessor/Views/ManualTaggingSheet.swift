import SwiftUI
import AppKit

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
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("← → image   Space = preview")
                    .font(.caption2).foregroundStyle(.tertiary)
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
                    .buttonStyle(.borderedProminent)
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
                                            .foregroundStyle(idx == focusedImage ? Color.accentColor : .secondary)
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

                // Date
                GroupBox("Date") {
                    HStack(alignment: .bottom, spacing: 12) {
                        dateField("Year", text: $segment.year, width: 70, prompt: "1968")
                        dateField("Month", text: $segment.month, width: 130, prompt: "03 March")
                        dateField("Day", text: $segment.day, width: 90, prompt: "Day 15")
                        Toggle("Date uncertain", isOn: $segment.dateUncertain)
                        if segment.dateLoading {
                            ProgressView().scaleEffect(0.6)
                            Text("estimating…").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(6)
                }

                // Subjects
                GroupBox("Subject tags") {
                    VStack(alignment: .leading, spacing: 4) {
                        TagInputField(tags: $segment.subjectTags, placeholder: "Type a subject and press Return…")
                        Text("Suggestions come from Finder tags already in use on your Mac.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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

    private func dateField(_ label: String, text: Binding<String>, width: CGFloat, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }
}
