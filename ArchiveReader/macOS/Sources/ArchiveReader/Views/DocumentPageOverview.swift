import SwiftUI
import PDFKit
import AppKit

/// Every physical PDF page, including the OCR pages. Only visible tiles hold bitmaps; no tile owns a
/// live PDFView. Opening a tile returns to the existing scan/OCR reading panes.
struct DocumentPageOverview: View {
    let path: String
    let pageCount: Int
    let selectedPage: Int
    let openPage: (Int) -> Void

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 20)], spacing: 20) {
                ForEach(0..<max(0, pageCount), id: \.self) { index in
                    DocumentPageTile(path: path, pageIndex: index, selected: selectedPage == index + 1) {
                        openPage(index + 1)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("ar.doc.pageOverview")
    }
}

struct DocumentPageTile: View {
    let path: String
    let pageIndex: Int
    let selected: Bool
    let open: () -> Void
    @State private var png: Data?
    @State private var finished = false

    var body: some View {
        Button(action: open) {
            DocumentPageTileLabel(png: png, pageNumber: pageIndex + 1, selected: selected, finished: finished)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("PDF page \(pageIndex + 1)")
        .accessibilityHint("Open this page in the scan and OCR reading view")
        .accessibilityIdentifier("ar.doc.pageTile.\(pageIndex + 1)")
        .task(id: path) {
            let rendered = await DocumentPageTileRenderer.shared.png(path: path, pageIndex: pageIndex)
            guard !Task.isCancelled else { return }
            png = rendered
            finished = true
        }
        .onDisappear { png = nil; finished = false }
    }
}

/// Kept separate so the actual tile, including its page image, is exercised by headless pixel guards.
struct DocumentPageTileLabel: View {
    let png: Data?
    let pageNumber: Int
    let selected: Bool
    let finished: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Color.white
                if let png, let image = NSImage(data: png) {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if finished {
                    Label("Preview unavailable", systemImage: "doc.questionmark")
                        .font(.callout).foregroundStyle(.black)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 240)
            .clipped()
            Text("PDF page \(pageNumber)").font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: selected ? 3 : 1))
        .contentShape(Rectangle())
    }
}

/// One serial background renderer. Each request opens its own read-only document, so PDFKit objects
/// never cross executors or race the viewer. Cancelled/offscreen requests skip decoding; no disk cache.
actor DocumentPageTileRenderer {
    static let shared = DocumentPageTileRenderer()

    func png(path: String, pageIndex: Int) -> Data? {
        guard !Task.isCancelled else { return nil }
        return autoreleasepool {
            guard let document = PDFDocument(url: URL(fileURLWithPath: path)),
                  pageIndex >= 0, pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else { return nil }
            let image = page.thumbnail(of: CGSize(width: 480, height: 480), for: .cropBox)
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
            return bitmap.representation(using: .png, properties: [:])
        }
    }
}
