import SwiftUI

// MARK: - The review of flagged boundaries (W36.seg-opt-review)

/// One flagged gap at a time, with up to three pages either side in a scrolling strip
/// (execution-plans/segmentation/04-options-build.md Part 3 §5). It asks one question: Split makes the right page
/// start a document, Join makes it continue the left one. The model's proposal, its confidence and its cue are not
/// shown, since a cue usually gives away which way the model leaned (W46.seg-check-blind). An answer is never final
/// until Done, which is enabled only once every flagged gap has one; Escape cancels the run, and nothing is written.
struct FlaggedBoundaryReviewSheet: View {
    @ObservedObject var processor: OCRProcessor
    @FocusState private var keyboardFocused: Bool

    private var items: [FlaggedGapItem] { processor.flaggedGapItems }
    private var focus: Int { min(max(0, processor.flaggedGapFocus), max(0, items.count - 1)) }
    private var answered: Int { items.filter { $0.answer != nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if items.indices.contains(focus) {
                gap(items[focus])
            } else {
                Spacer()
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 600, idealHeight: 740)
        .focusable()
        .focused($keyboardFocused)
        .focusEffectDisabled()
        .onAppear { keyboardFocused = true }
        .onKeyPress(characters: ["s", "S"]) { _ in answer(.split); return .handled }
        .onKeyPress(characters: ["j", "J"]) { _ in answer(.join); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.escape) {
            confirmDiscardRun("Your answers so far will be lost.") { processor.cancel() }
            return .handled
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Check Flagged Boundaries")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text((processor.flaggedReviewPartnerName.map {
                        "\(processor.flaggedReviewApproachName) and \($0) disagree about these boundaries, or one of them gave no answer. "
                    } ?? "\(processor.flaggedReviewApproachName) was unsure about these boundaries. ")
                     + "Does the right page start a new document, or continue the left one? Keys: S=Split  J=Join  \u{2190}\u{2192}=Move")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }
            Spacer()
            Text("\(focus + 1) of \(items.count)")
                .font(.headline)
                .monospacedDigit()
                .accessibilityIdentifier("flaggedReview.counter")
        }
        .padding()
    }

    private func gap(_ item: FlaggedGapItem) -> some View {
        VStack(spacing: 12) {
            Text("Up to three pages on each side. Scroll sideways for context; only your own answers are marked.")
                .font(.caption)
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                ScrollViewReader { scroll in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(item.displayedPages) { p in
                                let central = p.id == item.id || p.id == item.id + 1
                                page(p, central: central, before: p.id == item.id)
                                    .frame(width: central ? geometry.size.width * 0.32 : geometry.size.width * 0.16,
                                           height: central ? geometry.size.height - 16 : geometry.size.height * 0.62)
                                if p.id != item.displayedPages.last?.id {
                                    contextGap(after: p, item: item)
                                        .id(p.id == item.id ? "current-gap" : "gap-\(p.id)")
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                    }
                    .accessibilityIdentifier("flaggedReview.context")
                    .onAppear { scroll.scrollTo("current-gap", anchor: .center) }
                    .onChange(of: focus) { _, _ in scroll.scrollTo("current-gap", anchor: .center) }
                }
            }
            HStack(spacing: 12) {
                choice("Split", .split, item, help: "The right page starts a new document (S)")
                choice("Join", .join, item, help: "The right page continues the left one (J)")
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    private func page(_ p: FlaggedContextPage, central: Bool, before: Bool) -> some View {
        VStack(spacing: 4) {
            ArchiveThumbnail(url: p.url, maxSize: central ? 1600 : 600,
                             rotationDegrees: p.rotation, framed: true)
                .id(central)
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(central ? (before ? "Page before" : "Page after") : "Context")
                .fontWeight(central ? .semibold : .regular)
            Text("\(p.id + 1): \(p.url.lastPathComponent)")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(p.url.lastPathComponent)
        }
        .font(.caption)
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("flaggedReview.page.\(p.id)")
    }

    private func contextGap(after p: FlaggedContextPage, item: FlaggedGapItem) -> some View {
        let current = p.id == item.id
        // Match both URLs: only an answer on this actual adjacent pair belongs here. Never show proposals.
        let next = item.displayedPages.first { $0.id == p.id + 1 }
        let answer = items.first { $0.leftURL == p.url && $0.rightURL == next?.url }?.answer
        return VStack(spacing: 6) {
            if current {
                Text("Check\nthis gap")
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("flaggedReview.currentGap")
            } else if let answer {
                Text("Your answer:\n\(answer == .split ? "Split" : "Join")")
                    .accessibilityIdentifier("flaggedReview.answer.\(p.id)")
            }
            Rectangle()
                .fill(current ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: current ? 3 : 1, height: current ? 90 : 35)
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .foregroundStyle(current ? Color.accentColor : Color.primary)
        .frame(width: 56)
    }

    /// The chosen answer is drawn accent-filled, the others plain, so the pick reads at a glance and is not
    /// confused with a focus ring (W40.fix-processor-flagged-page-edges).
    private func choice(_ title: String, _ a: FlaggedGapAnswer, _ item: FlaggedGapItem, help: String) -> some View {
        let chosen = item.answer == a
        return Button { answer(a) } label: {
            Label(title, systemImage: chosen ? "checkmark.circle.fill" : "circle")
                .frame(minWidth: 90)
        }
        .buttonStyle(FlaggedChoiceButtonStyle(chosen: chosen))
        .help(help)
        .accessibilityIdentifier("flaggedReview.\(a.rawValue)")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            Button("Cancel Run", role: .cancel) {
                confirmDiscardRun("Your answers so far will be lost.") { processor.cancel() }
            }
            Button("Previous") { move(-1) }.disabled(focus == 0)
            Button("Next") { move(1) }.disabled(focus >= items.count - 1)
            Spacer()
            Text("\(answered) of \(items.count) answered")
                .font(.caption)
                .foregroundStyle(.primary)
                .accessibilityIdentifier("flaggedReview.answered")
            Button("Done") { processor.confirmFlaggedReview() }
                .prominentButtonStyle()
                .disabled(!FlaggedReview.isComplete(items))
                .accessibilityIdentifier("flaggedReview.done")
        }
        .padding()
    }

    /// Record the answer on the gap in view and move to the next unanswered one.
    private func answer(_ a: FlaggedGapAnswer) {
        guard items.indices.contains(focus) else { return }
        processor.flaggedGapItems[focus].answer = a
        let next = processor.flaggedGapItems.indices.first { $0 > focus && processor.flaggedGapItems[$0].answer == nil }
            ?? processor.flaggedGapItems.indices.first { processor.flaggedGapItems[$0].answer == nil }
        if let next { processor.flaggedGapFocus = next }
    }

    private func move(_ d: Int) {
        processor.flaggedGapFocus = min(max(0, focus + d), max(0, items.count - 1))
    }
}

/// Split / Join. `.borderedProminent` would mark the pick, but macOS greys it out whenever the
/// window is not key, which leaves picked and unpicked alike again; this fill holds in either state.
private struct FlaggedChoiceButtonStyle: ButtonStyle {
    let chosen: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        configuration.label
            .fontWeight(chosen ? .semibold : .regular)
            .foregroundStyle(chosen ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(shape.fill(chosen ? Color.accentColor : Color(nsColor: .controlColor)))
            .overlay(shape.strokeBorder(chosen ? Color.clear : Color.primary.opacity(0.2), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(shape)
    }
}
