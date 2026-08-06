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
        thumbnailer: PDFThumbnailer?
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
                page: nil
            )
            let urlString = link.url.absoluteString
            let display = file.url.deletingPathExtension().lastPathComponent

            plainURLs.append(urlString)
            entries.append(ArchiveLinkPayload.Entry(
                link: urlString,
                display: display,
                page: nil,
                thumbPNGBase64: nil
            ))
        }

        let item = NSPasteboardItem()
        // Rep 1: plain text (newline-joined URLs)
        item.setString(plainURLs.joined(separator: "\n"), forType: .string)

        // Rep 2: custom UTI JSON
        let payload = ArchiveLinkPayload(entries: entries)
        if let jsonData = try? JSONEncoder().encode(payload) {
            item.setData(jsonData, forType: NSPasteboard.PasteboardType(ArchiveLinkUTI.type))
        }

        return item
    }

    /// Build a pasteboard item for a single page-level link from the document viewer.
    /// Includes a base64 thumbnail if the thumbnailer is available.
    static func pageLink(
        fileURL: URL,
        page: Int,
        rootPath: String,
        marker: RootMarker,
        thumbnailer: PDFThumbnailer?
    ) async -> NSPasteboardItem {
        let filePath = fileURL.path
        let relativePath: String
        if filePath.hasPrefix(rootPath + "/") {
            relativePath = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            relativePath = fileURL.lastPathComponent
        }

        let link = DurableLink.readerReveal(
            rootGUID: marker.guid,
            relativePath: relativePath,
            page: page
        )
        let urlString = link.url.absoluteString
        let display = "\(fileURL.deletingPathExtension().lastPathComponent) \u{2014} p.\(page)"

        // Render thumbnail if possible
        var thumbBase64: String?
        if let thumbnailer {
            let mtime = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if let pngData = await thumbnailer.png(
                fileURL: fileURL, page: page,
                linkKey: urlString, mtime: mtime
            ) {
                thumbBase64 = pngData.base64EncodedString()
            }
        }

        let entry = ArchiveLinkPayload.Entry(
            link: urlString,
            display: display,
            page: page,
            thumbPNGBase64: thumbBase64
        )
        let payload = ArchiveLinkPayload(entries: [entry])

        let item = NSPasteboardItem()
        item.setString(urlString, forType: .string)
        if let jsonData = try? JSONEncoder().encode(payload) {
            item.setData(jsonData, forType: NSPasteboard.PasteboardType(ArchiveLinkUTI.type))
        }
        return item
    }
}
