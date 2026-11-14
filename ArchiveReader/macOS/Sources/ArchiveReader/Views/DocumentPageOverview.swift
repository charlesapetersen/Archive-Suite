import SwiftUI
import PDFKit
import AppKit

/// View ▸ Contact Sheet (⌥⌘6; "All Pages Tiled" until W40.reader-page-views): every physical PDF page of every
/// open file, OCR pages and an odd trailing scan included (W40.reader-tiled-pages), under a heading per file when
/// more than one is open. Only visible tiles hold bitmaps, read from the on-disk thumbnail cache; no tile owns a
/// live PDFView. Opening a tile returns to the scan/OCR reading panes on that page.
struct DocumentPageOverview: View {
    @ObservedObject var model: DocumentViewerModel
    @ObservedObject var pages: OpenFilePageCounts
    /// "ar.doc" or "ar.preview": the window the sheet is in, for the accessibility identifiers.
    let idPrefix: String
    /// Called after a tile opens its page, so the window can give the reading pane the keyboard.
    var opened: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { grid }
                // A turn later, once the lazy grid has laid out its first rows.
                .onAppear {
                    DispatchQueue.main.async { proxy.scrollTo(PageSlot(file: model.index, index: model.focusedPageNumber - 1)) }
                }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("\(idPrefix).pageOverview")
    }

    /// The scroll view's content, apart so the render guards can draw it (`ImageRenderer` draws no scroll view).
    /// One grid for every page of every file, as Preview lays its contact sheet out (W40.reader-contact-sheet-grid):
    /// a section per file broke the rows at each file, so a selection of two-page files read as a list of pairs.
    /// The rows fill the width and reflow when the window is resized; each file's first tile carries its heading.
    var grid: some View {
        let files = Array(model.urls.enumerated())
        let cells = ContactSheetCell.cells(files: files.map { $0.element.path }, count: pages.count)
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 18)],
                         alignment: .leading, spacing: 18) {
            // One `ForEach` whatever is known: until a count is read the file's first page stands in, and the
            // cells keep their identity when it arrives. Swapping in a second branch with the same ids left a
            // stale cell in the lazy stack, one that did not follow the page on view (seen in the VM).
            ForEach(cells) { cell in
                tile(cell, name: files[cell.slot.file].element.lastPathComponent, fileCount: files.count)
                    .task(id: cell.path) { if cell.slot.index == 0 { await pages.request(cell.path) } }
            }
        }
        .padding(18)
    }

    private func tile(_ cell: ContactSheetCell, name: String, fileCount: Int) -> some View {
        let file = cell.slot.file, pageIndex = cell.slot.index, number = pageIndex + 1
        let several = fileCount > 1, current = file == model.index
        let turns = pages.pairs(cell.path).isImagePage(pageIndex) ? model.pageTurns.turns(path: cell.path, page: pageIndex) : 0
        return VStack(spacing: 4) {
            if several {
                // Every tile keeps the heading's line so the rows stay level; only a file's first page fills it.
                if pageIndex == 0 {
                    OpenFileHeader(name: name, position: "\(file + 1) of \(fileCount)", current: current)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .help(name)
                } else {
                    OpenFileHeader(name: name, position: "", current: current).hidden().accessibilityHidden(true)
                }
            }
            if cell.unreadable {
                Label("Cannot be opened", systemImage: "exclamationmark.triangle").font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 248)
            } else {
                PageThumbnailCell(path: cell.path, pageIndex: pageIndex, turns: turns, label: "PDF page \(number)",
                                  selected: current && number == model.focusedPageNumber,
                                  height: 220, maxPixel: 520, inverted: model.invertingImages,
                                  identifier: "\(idPrefix).pageTile.\(file + 1).\(number)",
                                  accessibilityLabel: several ? "\(name), PDF page \(number)" : "PDF page \(number)") {
                    model.openTiledPage(file: file, page: number)
                    opened()
                }
                .accessibilityHint("Open this page in the scan and OCR reading view")
            }
        }
        .padding(8)
        // The pages of the file on view sit on a tint, as its heading did when each file was a section.
        .background(several && current ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// One tile of the contact sheet: a page of an open file, or the one tile of a file that cannot be opened.
struct ContactSheetCell: Identifiable, Hashable {
    let slot: PageSlot
    let path: String
    let unreadable: Bool
    var id: PageSlot { slot }

    /// Every file's pages in order, in one run. A file whose count is not read yet has its first page; one that
    /// cannot be opened (0 pages) has a single unreadable tile under the same id, so the cell keeps its identity.
    static func cells(files: [String], count: (String) -> Int?) -> [ContactSheetCell] {
        files.enumerated().flatMap { file, path -> [ContactSheetCell] in
            let pages = count(path)
            if pages == 0 { return [ContactSheetCell(slot: PageSlot(file: file, index: 0), path: path, unreadable: true)] }
            return PageSlot.slots(file: file, count: pages ?? 1).map { ContactSheetCell(slot: $0, path: path, unreadable: false) }
        }
    }
}

/// A cell of the page views: a file and a page (the contact sheet) or a page pair (the thumbnails). Unique across
/// files, so it is both the cell's identity and what the views scroll to.
struct PageSlot: Hashable {
    let file: Int
    let index: Int

    static func slots(file: Int, count: Int) -> [PageSlot] { (0..<max(0, count)).map { PageSlot(file: file, index: $0) } }
}

/// View ▸ Thumbnails (⌥⌘2): a sidebar of the image pages of every open file, in order, one per page pair — the
/// OCR text pages are not shown (`DocumentPagePairs`), since the reading pane beside it shows them. The file on
/// view is marked, and the thumbnail on view outlined and kept in sight. Clicking one goes to it.
struct PageThumbnailSidebar: View {
    @ObservedObject var model: DocumentViewerModel
    @ObservedObject var pages: OpenFilePageCounts
    let idPrefix: String
    static let width: CGFloat = 150

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { list }
            // The path is in the key: the preview sheet reloads every file it browses to on file 0, pair 0.
            .onChange(of: "\(model.currentFilePath ?? "")#\(model.pageIdentity)", initial: true) {
                DispatchQueue.main.async { proxy.scrollTo(PageSlot(file: model.index, index: model.pair)) }
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thumbnails")
        .accessibilityIdentifier("\(idPrefix).thumbnails")
    }

    /// The scroll view's content, apart so the render guards can draw it.
    var list: some View {
        let files = Array(model.urls.enumerated())
        let several = files.count > 1
        return LazyVStack(spacing: 10, pinnedViews: several ? [.sectionHeaders] : []) {
            ForEach(files, id: \.element) { file, url in
                Section {
                    thumbnails(file: file, path: url.path)
                } header: {
                    if several {
                        OpenFileHeader(name: url.lastPathComponent, position: "\(file + 1)/\(files.count)",
                                       current: file == model.index)
                    }
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
    }

    /// One `ForEach` whatever is known, as in the contact sheet.
    @ViewBuilder private func thumbnails(file: Int, path: String) -> some View {
        let count = pages.count(path)
        if count == 0 {
            Label("Cannot be opened", systemImage: "exclamationmark.triangle").font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(PageSlot.slots(file: file, count: count.map { _ in pages.pairs(path).count } ?? 1),
                id: \.self) { slot in
            thumbnail(file: file, path: path, pair: slot.index)
                .task(id: path) { if slot.index == 0 { await pages.request(path) } }
        }
    }

    private func thumbnail(file: Int, path: String, pair: Int) -> some View {
        let pageIndex = pages.pairs(path).imagePageIndex(pair: pair)
        return PageThumbnailCell(path: path, pageIndex: pageIndex,
                                 turns: model.pageTurns.turns(path: path, page: pageIndex), label: "\(pair + 1)",
                                 selected: file == model.index && pair == model.pair && !model.showingAllPages,
                                 height: 150, maxPixel: 340, inverted: model.invertingImages, identifier: "\(idPrefix).thumb.\(file + 1).\(pair + 1)",
                                 accessibilityLabel: "Page \(pair + 1) of file \(file + 1)") {
            model.openThumbnail(file: file, pair: pair)
        }
    }
}

/// The toolbar's (and the preview sheet's) two page-view buttons, beside View ▸ Show Thumbnails and Contact Sheet.
struct PageViewButtons: View {
    @ObservedObject var model: DocumentViewerModel
    let idPrefix: String

    var body: some View {
        Button { model.toggleThumbnails() } label: {
            Label(ReaderCommand.showThumbnails.title(showing: model.pageView == .thumbnails), systemImage: "sidebar.left")
        }
        .disabled(!model.canShowThumbnails)
        .help(model.pageView == .thumbnails
              ? "Hide the thumbnails (\(ReaderCommand.showThumbnails.glyph))"
              : "Show a thumbnail of each scan of the open files beside the page (\(ReaderCommand.showThumbnails.glyph))")
        .accessibilityIdentifier("\(idPrefix).thumbnailsButton")
        Button { model.setShowingAllPages(!model.showingAllPages) } label: {
            Label(model.showingAllPages ? "Read Selected Page" : ReaderCommand.contactSheet.title,
                  systemImage: model.showingAllPages ? "doc.text.image" : "square.grid.2x2")
        }
        .disabled(!model.canShowAllPages)
        .help(model.showingAllPages
              ? "Return to the selected scan and OCR text"
              : "View every PDF page of the open files as a numbered tile; click a tile to read it (\(ReaderCommand.contactSheet.glyph))")
        .accessibilityIdentifier("\(idPrefix).allPages")
    }
}
