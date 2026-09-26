// ArchiveLinkWriter.swift — builds multi-representation pasteboard items for Copy Archive Link(s).
// Representation 1: plain-text newline-joined archivereader:// URLs.
// Representation 2: custom UTI JSON (ArchiveLinkPayload) with display labels + optional base64 thumbs.

import AppKit
import ArchiveCore

enum ArchiveLinkWriter {
    /// Build an `NSPasteboardItem` carrying both plain-text URLs and the rich JSON payload.
    /// `files` are the selected archive files; `rootPath` is the granted root spelled the way
    /// discovery reports paths under it (`RootFolderStore.discoveredPathPrefix`) — NOT the root URL's
    /// own `path`, which under an aliased or symlinked root matches nothing the walk produced, so
    /// every link degraded to a bare `lastPathComponent` (`W26.symroot-fu1`); `marker` provides the
    /// stable root GUID for durable links.
    /// Thumbnail rendering is async (via the PDFThumbnailer actor) so this method is async.
    static func pasteboardItem(
        for files: [ArchiveFile],
        rootPath: String,
        marker: RootMarker,
        thumbnailer: PDFThumbnailer?,
        mainRootPath: String? = nil,
        jpegPartnerIndex: JPEGPartnerIndex? = nil
    ) async -> NSPasteboardItem {
        let rootGUID = marker.guid

        var entries: [ArchiveLinkPayload.Entry] = []
        var plainURLs: [String] = []

        for file in files {
            let filePath = file.url.path
            // Root-relative path: strip "root/" prefix, keep forward slashes.
            let relativePath: String
            if filePath.hasPrefix(rootPath + "/") {
                relativePath = String(filePath.dropFirst(rootPath.count + 1))
            } else {
                relativePath = file.url.lastPathComponent
            }

            let link = DurableLink.readerReveal(
                rootGUID: rootGUID,
                relativePath: relativePath,
                page: nil,
                jpegRelativePath: partnerRelativePath(for: file.url, rootPath: rootPath,
                                                       mainRootPath: mainRootPath,
                                                       index: jpegPartnerIndex)
            )
            let urlString = link.url.absoluteString
            let display = file.url.deletingPathExtension().lastPathComponent

            // A document-level link names no specific page, but its preview can still use page 1.
            // The durable link remains document-level; this is only an optional, self-contained
            // representation for a Notes source block. Rendering failure degrades to the same link
            // payload rather than withholding the copy action.
            let mtime = (try? file.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            // A known cloud placeholder is deliberately never opened merely for an optional preview.
            // `PDFThumbnailer` also owns a no-materialisation guard for the local→dataless race.
            let thumbnailData = file.isDataless ? nil : await thumbnailer?.png(
                fileURL: file.url, page: 1, linkKey: urlString, mtime: mtime
            )

            plainURLs.append(urlString)
            entries.append(ArchiveLinkPayload.Entry(
                link: urlString,
                display: display,
                page: nil,
                thumbPNGBase64: thumbnailData?.base64EncodedString()
            ))
        }

        return pasteboardItem(entries: entries, plainURLs: plainURLs)
    }

    /// Immediate text-first representation for a copy command while optional thumbnail rendering runs.
    /// It has the same durable links and rich UTI as the final item, just no preview bytes yet.
    static func pasteboardItemWithoutThumbnails(
        for files: [ArchiveFile], rootPath: String, marker: RootMarker,
        mainRootPath: String? = nil, jpegPartnerIndex: JPEGPartnerIndex? = nil
    ) -> NSPasteboardItem {
        var entries: [ArchiveLinkPayload.Entry] = []
        var plainURLs: [String] = []
        for file in files {
            let relativePath = file.url.path.hasPrefix(rootPath + "/")
                ? String(file.url.path.dropFirst(rootPath.count + 1))
                : file.url.lastPathComponent
            let link = DurableLink.readerReveal(
                rootGUID: marker.guid, relativePath: relativePath, page: nil,
                jpegRelativePath: partnerRelativePath(for: file.url, rootPath: rootPath,
                                                       mainRootPath: mainRootPath,
                                                       index: jpegPartnerIndex)
            )
            let urlString = link.url.absoluteString
            plainURLs.append(urlString)
            entries.append(ArchiveLinkPayload.Entry(
                link: urlString, display: file.url.deletingPathExtension().lastPathComponent, page: nil
            ))
        }
        return pasteboardItem(entries: entries, plainURLs: plainURLs)
    }

    /// Build a pasteboard item for a single page-level link from the document viewer.
    /// Includes a base64 thumbnail if the thumbnailer is available.
    static func pageLink(
        fileURL: URL,
        page: Int,
        rootPath: String,
        marker: RootMarker,
        thumbnailer: PDFThumbnailer?,
        mainRootPath: String? = nil,
        jpegPartnerIndex: JPEGPartnerIndex? = nil
    ) async -> NSPasteboardItem {
        let base = pagePayload(fileURL: fileURL, page: page, rootPath: rootPath, marker: marker,
                               mainRootPath: mainRootPath, jpegPartnerIndex: jpegPartnerIndex)

        // Render thumbnail if possible
        var thumbBase64: String?
        if let thumbnailer {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if let pngData = await thumbnailer.png(
                fileURL: fileURL, page: page,
                linkKey: base.urlString, mtime: mtime
            ) {
                thumbBase64 = pngData.base64EncodedString()
            }
        }

        let entry = ArchiveLinkPayload.Entry(
            link: base.urlString,
            display: base.display,
            page: page,
            thumbPNGBase64: thumbBase64
        )
        return pasteboardItem(entries: [entry], plainURLs: [base.urlString])
    }

    /// Text-first page link used immediately by the command while its optional image renders.
    static func pageLinkWithoutThumbnail(
        fileURL: URL, page: Int, rootPath: String, marker: RootMarker,
        mainRootPath: String? = nil, jpegPartnerIndex: JPEGPartnerIndex? = nil
    ) -> NSPasteboardItem {
        let base = pagePayload(fileURL: fileURL, page: page, rootPath: rootPath, marker: marker,
                               mainRootPath: mainRootPath, jpegPartnerIndex: jpegPartnerIndex)
        let entry = ArchiveLinkPayload.Entry(link: base.urlString, display: base.display, page: page)
        return pasteboardItem(entries: [entry], plainURLs: [base.urlString])
    }

    private static func pagePayload(
        fileURL: URL, page: Int, rootPath: String, marker: RootMarker,
        mainRootPath: String?, jpegPartnerIndex: JPEGPartnerIndex?
    ) -> (urlString: String, display: String) {
        let relativePath = fileURL.path.hasPrefix(rootPath + "/")
            ? String(fileURL.path.dropFirst(rootPath.count + 1))
            : fileURL.lastPathComponent
        let link = DurableLink.readerReveal(
            rootGUID: marker.guid, relativePath: relativePath, page: page,
            jpegRelativePath: partnerRelativePath(for: fileURL, rootPath: rootPath,
                                                   mainRootPath: mainRootPath,
                                                   index: jpegPartnerIndex)
        )
        return (link.url.absoluteString, "\(fileURL.deletingPathExtension().lastPathComponent) \u{2014} p.\(page)")
    }

    private static func partnerRelativePath(for pdfURL: URL, rootPath: String,
                                            mainRootPath: String?,
                                            index: JPEGPartnerIndex?) -> String? {
        guard let mainRootPath, let index,
              case let .match(partnerURL) = index.resolve(
                pdfURL: pdfURL, mainRoot: URL(fileURLWithPath: mainRootPath, isDirectory: true)
              ) else { return nil }
        let path = partnerURL.withUnsafeFileSystemRepresentation { raw in raw.map(String.init(cString:)) ?? partnerURL.path }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private static func pasteboardItem(
        entries: [ArchiveLinkPayload.Entry], plainURLs: [String]
    ) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(plainURLs.joined(separator: "\n"), forType: .string)
        if let jsonData = try? JSONEncoder().encode(ArchiveLinkPayload(entries: entries)) {
            item.setData(jsonData, forType: NSPasteboard.PasteboardType(ArchiveLinkUTI.type))
        }
        return item
    }
}

/// The production renderer shared by Reader's page and batch copy paths. Its cache is app-owned and
/// disposable: it is never derived from, or written into, the archive root.
enum ArchiveLinkThumbnailer {
    static let shared = PDFThumbnailer(cacheDirectory: cacheDirectory)

    private static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("ArchiveReader", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()
}
