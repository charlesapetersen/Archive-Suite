import SwiftUI
import AppKit
import ArchiveCore

/// Reader-only guidance: these are observed symptoms, not a diagnosis of corruption or an OCR failure.
struct FileHealthDetail {
    enum Action { case openDocument, revealInFinder, editInfo }
    struct Issue {
        let title: String
        let reason: String
        let remedy: String
    }
    let file: ArchiveFile
    let status: PDFFormatStatus?

    var pdfIssue: Issue? {
        switch status {
        case .unreadable:
            Issue(title: "PDF could not be opened",
                  reason: "Reader could not read this PDF. It may be damaged, password-protected, or not a PDF despite its name.",
                  remedy: "Reveal the file in Finder and check it in Preview. If needed, unlock it or replace it with a readable copy. Reader will check the changed file again.")
        case .noTextLayer:
            Issue(title: "No selectable text",
                  reason: "This PDF opens, but Reader found no selectable text. OCR text search cannot find its contents.",
                  remedy: "Open the document to inspect it. To make it searchable, use an OCR tool to create a searchable PDF, then put the corrected copy in the archive. Reader will check the changed file again.")
        case .standard, nil: nil
        }
    }

    var dateIssue: Issue? {
        file.dateAmbiguityText.map {
            Issue(title: "Conflicting date tags", reason: $0,
                  remedy: "Open Edit Info for this file. Remove a wrong set-aside tag under Tags, or replace the date that is being used in the date fields.")
        }
    }

    var tooltip: String {
        [pdfIssue, dateIssue].compactMap { $0 }.map { "\($0.title): \($0.reason) \($0.remedy)" }
            .joined(separator: "\n\n") + "\nClick for details and actions."
    }
}

struct FileHealthView: View {
    let detail: FileHealthDetail
    let onAction: (FileHealthDetail.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detail.file.name).font(.headline).textSelection(.enabled)
            Text(detail.file.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let issue = detail.pdfIssue {
                issueView(issue)
                HStack {
                    Button("Open Document") { onAction(.openDocument) }
                        .accessibilityIdentifier("ar.fileHealth.open")
                    Button("Reveal in Finder") { onAction(.revealInFinder) }
                        .accessibilityIdentifier("ar.fileHealth.reveal")
                }
            }
            if let issue = detail.dateIssue {
                issueView(issue)
                Button("Edit Info…") { onAction(.editInfo) }
                    .accessibilityIdentifier("ar.fileHealth.editInfo")
            }
        }
        .padding(16)
        .frame(width: 370, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func issueView(_ issue: FileHealthDetail.Issue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.title).font(.headline)
            Text(issue.reason)
            Text(issue.remedy)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A real button over the existing tinted label keeps the small glyph's selection contrast. The whole
/// date cell is clickable when it carries an alert; an ordinary date or empty warning stays a plain cell.
@MainActor
final class FileHealthCellView: TintedTextCellView {
    private(set) var detail: FileHealthDetail?
    private(set) var actionButton: NSButton?
    private(set) var popover: NSPopover?
    private var onAction: (FileHealthDetail.Action) -> Void = { _ in }

    func configure(detail: FileHealthDetail?, onAction: @escaping (FileHealthDetail.Action) -> Void) {
        // Index batches redraw visible rows. An unchanged file must not dismiss details while someone
        // is reading them. A changed issue or a different file closes the old presentation.
        let unchanged = self.detail?.file.path == detail?.file.path
            && self.detail?.status == detail?.status
            && self.detail?.file.dateAmbiguityText == detail?.file.dateAmbiguityText
        self.detail = detail
        self.onAction = onAction
        textField?.toolTip = detail?.tooltip
        if unchanged, actionButton != nil { return }
        popover?.close()
        popover = nil
        actionButton?.removeFromSuperview()
        actionButton = nil
        guard let detail else { return }
        let button = NSButton(title: "", target: self, action: #selector(showDetails))
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = detail.tooltip
        button.setAccessibilityLabel("File health for \(detail.file.name). \(detail.tooltip)")
        button.setAccessibilityIdentifier("ar.fileHealth.\(identifier?.rawValue ?? "cell").\(detail.file.path)")
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        actionButton = button
    }

    /// Snapshot both the named file and its actions. A cell being reused cannot retarget an open popover.
    func makeDetailView() -> FileHealthView? {
        guard let detail else { return nil }
        let action = onAction
        return FileHealthView(detail: detail) { [weak self] choice in
            self?.popover?.close()
            action(choice)
        }
    }

    @objc private func showDetails() {
        guard let view = makeDetailView(), let button = actionButton, window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: view)
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }
}
