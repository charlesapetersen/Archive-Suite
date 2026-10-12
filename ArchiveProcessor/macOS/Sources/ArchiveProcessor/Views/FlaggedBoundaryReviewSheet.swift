import SwiftUI

// MARK: - The review of flagged boundaries (W36.seg-opt-review)

/// One flagged gap at a time, page n on the left and page n+1 on the right
/// (execution-plans/segmentation/04-options-build.md Part 3 §5). Keep accepts the proposal, Split makes the right
/// page start a document, Join makes it continue the left one. An answer is never final until Done, which is
/// enabled only once every flagged gap has one; Escape cancels the run, and nothing is written.
struct FlaggedBoundaryReviewSheet: View {
    @ObservedObject var processor: OCRProcessor

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
        .frame(minWidth: 900, minHeight: 600)
        .accessibilityIdentifier("flaggedReview.sheet")
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) { answer(.keep); return .handled }
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
                Text("\(processor.flaggedReviewApproachName) was unsure about these boundaries. "
                     + "Keys: Return=Keep  S=Split  J=Join  \u{2190}\u{2192}=Move")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            VStack(spacing: 4) {
                Text(item.proposalText)
                    .font(.headline)
                    .accessibilityIdentifier("flaggedReview.proposal")
                Text(item.confidenceText + (item.shortCue.isEmpty ? "" : " · \(item.shortCue)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)
            HStack(spacing: 16) {
                page(item.leftURL, rotation: item.leftRotation, caption: "Page before")
                page(item.rightURL, rotation: item.rightRotation, caption: "Page after")
            }
            .padding(.horizontal)
            HStack(spacing: 12) {
                choice("Keep", .keep, item, help: "Accept the proposal (Return)")
                choice("Split", .split, item, help: "The right page starts a new document (S)")
                choice("Join", .join, item, help: "The right page continues the left one (J)")
            }
            .padding(.bottom, 8)
        }
    }

    private func page(_ url: URL, rotation: Int, caption: String) -> some View {
        VStack(spacing: 4) {
            ArchiveThumbnail(url: url, maxSize: 1600, rotationDegrees: rotation)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("\(caption): \(url.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func choice(_ title: String, _ a: FlaggedGapAnswer, _ item: FlaggedGapItem, help: String) -> some View {
        Button { answer(a) } label: {
            Label(title, systemImage: item.answer == a ? "checkmark.circle.fill" : "circle")
                .frame(minWidth: 90)
        }
        .controlSize(.large)
        .help(help)
        .accessibilityIdentifier("flaggedReview.\(a.rawValue)")
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
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("flaggedReview.answered")
            Button("Done") { processor.confirmFlaggedReview() }
                .buttonStyle(.borderedProminent)
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
