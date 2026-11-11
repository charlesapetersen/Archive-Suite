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
                .onAppear { proxy.scrollTo(tileID(model.index, model.focusedPageNumber)) }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .accessibilityIdentifier("\(idPrefix).pageOverview")
    }

    /// The scroll view's content, apart so the render guards can draw it (`ImageRenderer` draws no scroll view).
    var grid: some View {
        let files = Array(model.urls.enumerated())
        let several = files.count > 1
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 18)], spacing: 18,
                         pinnedViews: several ? [.sectionHeaders] : []) {
            ForEach(files, id: \.offset) { file, url in
                Section {
                    tiles(file: file, path: url.path)
                } header: {
                    if several {
                        OpenFileHeader(name: url.lastPathComponent, position: "\(file + 1) of \(files.count)",
                                       current: file == model.index)
                    }
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder private func tiles(file: Int, path: String) -> some View {
        if let count = pages.count(path) {
            if count == 0 {
                Label("Cannot be opened", systemImage: "exclamationmark.triangle").font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<count, id: \.self) { index in tile(file: file, path: path, pageIndex: index) }
        } else {
            // Until the count is read, the first page stands in; reading it is what scrolling here asks for.
            tile(file: file, path: path, pageIndex: 0).task { await pages.request(path) }
        }
    }

    private func tile(file: Int, path: String, pageIndex: Int) -> some View {
        let number = pageIndex + 1
        let turns = DocumentPagePairs.isImagePage(pageIndex) ? model.pageTurns.turns(path: path, page: pageIndex) : 0
        return PageThumbnailCell(path: path, pageIndex: pageIndex, turns: turns, label: "PDF page \(number)",
                                 selected: file == model.index && number == model.focusedPageNumber,
                                 height: 220, maxPixel: 520, identifier: "\(idPrefix).pageTile.\(file + 1).\(number)",
                                 accessibilityLabel: "PDF page \(number)") {
            model.openTiledPage(file: file, page: number)
            opened()
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHint("Open this page in the scan and OCR reading view")
        .id(tileID(file, number))
    }

    private func tileID(_ file: Int, _ page: Int) -> String { "tile#\(file)#\(page)" }
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
            .onChange(of: model.pageIdentity, initial: true) {
                proxy.scrollTo(thumbnailID(model.index, model.pair))
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
            ForEach(files, id: \.offset) { file, url in
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

    @ViewBuilder private func thumbnails(file: Int, path: String) -> some View {
        if let count = pages.count(path) {
            if count == 0 {
                Label("Cannot be opened", systemImage: "exclamationmark.triangle").font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(0..<DocumentPagePairs.pairCount(pageCount: count), id: \.self) { pair in
                thumbnail(file: file, path: path, pair: pair)
            }
        } else {
            thumbnail(file: file, path: path, pair: 0).task { await pages.request(path) }
        }
    }

    private func thumbnail(file: Int, path: String, pair: Int) -> some View {
        let pageIndex = DocumentPagePairs.imagePageIndex(pair: pair)
        return PageThumbnailCell(path: path, pageIndex: pageIndex,
                                 turns: model.pageTurns.turns(path: path, page: pageIndex), label: "\(pair + 1)",
                                 selected: file == model.index && pair == model.pair && !model.showingAllPages,
                                 height: 150, maxPixel: 280, identifier: "\(idPrefix).thumb.\(file + 1).\(pair + 1)",
                                 accessibilityLabel: "Page \(pair + 1) of file \(file + 1)") {
            model.openThumbnail(file: file, pair: pair)
        }
        .id(thumbnailID(file, pair))
    }

    private func thumbnailID(_ file: Int, _ pair: Int) -> String { "thumb#\(file)#\(pair)" }
}

/// The toolbar's (and the preview sheet's) two page-view buttons, beside View ▸ Thumbnails and Contact Sheet.
struct PageViewButtons: View {
    @ObservedObject var model: DocumentViewerModel
    let idPrefix: String

    var body: some View {
        Button { model.setPageView(model.pageView == .thumbnails ? .single : .thumbnails) } label: {
            Label(ReaderCommand.thumbnails.title, systemImage: "sidebar.left")
        }
        .disabled(!model.canShowThumbnails)
        .help(model.pageView == .thumbnails
              ? "Hide the thumbnails (\(ReaderCommand.singlePage.glyph))"
              : "Show a thumbnail of each scan of the open files beside the page (\(ReaderCommand.thumbnails.glyph))")
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
