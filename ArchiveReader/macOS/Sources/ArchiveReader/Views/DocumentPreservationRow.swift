import AppKit
import ArchiveCore
import PDFKit
import SwiftUI

/// A read-only route to the source of the displayed image page.
struct DocumentPreservationRow: View {
    @ObservedObject var rootStore: RootFolderStore
    let file: URL
    let identity: CataloguePDFIdentity?
    let pageIndex: Int

    @State private var state: Result<PreservationCopy.Selection, PreservationCopy.Failure>?
    @State private var original: PreservationCopy.Original?
    @State private var opening: Task<Void, Never>?
    @State private var requestToken = UUID()
    @State private var checkNumber = 0

    private struct Check: Equatable {
        let request: Request?
        let number: Int
    }

    private struct Request: Equatable, Sendable {
        let root: URL
        let file: URL
        let identity: CataloguePDFIdentity
        let pageIndex: Int

        func read<T>(_ action: (CatalogueReader, CatalogueAssociation.Occurrence) throws -> T) throws -> T {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let relative = CorpusWalker.withDatalessMaterializationDisabled {
                CorpusWalker.discoveredPathPrefix(for: root).flatMap { ReaderCatalogueScan.relativePath(of: file, under: $0) }
                    ?? ReaderCatalogueScan.relativePath(of: file, under: root.standardizedFileURL.path)
            }
            guard let relative else { throw PreservationCopy.Failure.notRecorded }
            let instance = UUID()
            let reader = try CatalogueReader(grantedRoot: root, rootInstanceID: instance, mode: .adopted,
                                             identifyPDF: CataloguePDFIdentity.identify)
            return try action(reader, .init(rootInstanceID: instance, relativePath: relative))
        }
    }

    private var request: Request? {
        guard let root = rootStore.root, let identity else { return nil }
        return Request(root: root, file: file, identity: identity, pageIndex: pageIndex)
    }

    var body: some View {
        let current = request
        HStack(spacing: 8) {
            Text("Preservation copy").fontWeight(.medium)
            Text(statusText)   // not `.secondary`: 3.95:1 at caption size in light mode
                .accessibilityIdentifier("ar.doc.preservation.status")
            Spacer()
            if opening != nil { ProgressView().controlSize(.small) }
            if let current {
                switch state {
                case .success:
                    Button("View original") { viewOriginal(current) }
                        .disabled(opening != nil)
                        .accessibilityIdentifier("ar.doc.preservation.open")
                case .failure(.missing), .failure(.offline), .failure(.unverified):
                    Button("Check again") { checkNumber += 1 }
                        .accessibilityIdentifier("ar.doc.preservation.check")
                default:
                    EmptyView()
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .task(id: Check(request: current, number: checkNumber)) {
            clearSelection()
            guard let current else { return }
            let work = Task.detached(priority: .utility) {
                Result {
                    try current.read { reader, occurrence in
                        try PreservationCopy.status(in: reader, at: occurrence, physicalPageIndex: current.pageIndex,
                                                    expected: current.identity)
                    }
                }.mapError { $0 as? PreservationCopy.Failure ?? .unverified }
            }
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, current == request else { return }
            state = result
        }
        .onDisappear { clearSelection() }
        .sheet(isPresented: Binding(get: { original != nil }, set: { if !$0 { original = nil } })) {
            if let original { PreservationOriginalSheet(original: original, root: rootStore.root) }
        }
    }

    private var statusText: String {
        switch state {
        case .success(let selection): selection.source.name
        case .failure(.missing): "Preservation copy missing"
        case .failure(.offline): "Available to download"
        case .failure(.unverified): "Could not verify"
        case .failure(.notRecorded): "Not recorded"
        case nil: request == nil ? "Not recorded" : "Checking…"
        }
    }

    private func clearSelection() {
        requestToken = UUID()
        opening?.cancel()
        opening = nil
        original = nil
        state = nil
    }

    private func viewOriginal(_ current: Request) {
        let token = UUID()
        requestToken = token
        let work = Task.detached(priority: .userInitiated) {
            Result {
                try current.read { reader, occurrence in
                    try PreservationCopy.open(in: reader, at: occurrence, physicalPageIndex: current.pageIndex,
                                              expected: current.identity)
                }
            }
        }
        opening = Task {
            let result = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard requestToken == token else { return }
            opening = nil
            guard !Task.isCancelled, current == request else { return }
            switch result {
            case .success(let value): original = value
            case .failure(let error): state = .failure(error as? PreservationCopy.Failure ?? .unverified)
            }
        }
    }
}

private struct PreservationOriginalSheet: View {
    let original: PreservationCopy.Original
    let root: URL?
    @Environment(\.dismiss) private var dismiss
    @State private var controller = PDFPaneController(key: "ar.preservation", persists: false)
    @State private var page: PDFPage?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(original.selection.source.name).font(.headline)
                    Text(original.selection.source.format == .pdf
                         ? "Original orientation · page \(original.selection.originalPageIndex + 1)"
                         : "Original orientation")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") {
                    let scoped = root?.startAccessingSecurityScopedResource() ?? false
                    defer { if scoped { root?.stopAccessingSecurityScopedResource() } }
                    NSWorkspace.shared.activateFileViewerSelecting([original.fileURL])
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            if let page {
                PDFPaneView(page: page, controller: controller, id: "ar.doc.preservation.preview")
            } else if loaded {
                ContentUnavailableView("Could not display the original", systemImage: "doc.questionmark")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(14)
        .frame(minWidth: 640, minHeight: 480)
        .task {
            page = PreservationOriginalPage.make(bytes: original.bytes, format: original.selection.source.format,
                                                 index: original.selection.originalPageIndex)
            loaded = true
        }
    }
}

@MainActor
enum PreservationOriginalPage {
    static func make(bytes: Data, format: PreservationCopy.Format, index: Int) -> PDFPage? {
        if format == .pdf {
            guard let document = PDFDocument(data: bytes), index >= 0, index < document.pageCount else { return nil }
            return document.page(at: index)?.copy() as? PDFPage
        }
        return NSImage(data: bytes).flatMap { PDFPage(image: $0) }
    }
}
