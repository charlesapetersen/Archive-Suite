// SourceBlockThumbnailRendererTests.swift — W9.b4 headless pasted-page thumbnail guard.
//
// Everything here is a temporary Reader-shaped root. It proves Notes' production fallback renders
// actual page pixels when a rich Reader payload lacks a thumbnail, without searching outside the
// exact durable-link path or touching a real corpus.

import Testing
import Foundation
import AppKit
import CoreGraphics
import ArchiveCore
@testable import ArchiveNotes

@MainActor
@Suite("Pasted Reader page thumbnail fallback (W9.b4)")
struct SourceBlockThumbnailRendererTests {

    private func makeScratchRoot() throws -> (root: URL, marker: RootMarker) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceBlockThumbnailRenderer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let marker = RootMarker(guid: UUID(), name: "Scratch Reader", kind: .reader, createdAt: Date())
        try JSONEncoder().encode(marker).write(
            to: root.appendingPathComponent(RootMarker.filename), options: .atomic
        )
        return (root, marker)
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "ArchiveNotesTests.SourceBlockThumbnailRenderer.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    private func writeInkyPDF(to url: URL) throws {
        let page = CGRect(x: 0, y: 0, width: 400, height: 520)
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        var mediaBox = page
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(page)
        // A large black rectangle makes this a pixel guard rather than a mere valid-PNG check.
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 80, y: 100, width: 240, height: 320))
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }

    private func anchor(marker: RootMarker, relativePath: String, page: Int = 1) -> SourceAnchor {
        SourceAnchor(
            link: DurableLink.readerReveal(rootGUID: marker.guid, relativePath: relativePath, page: page).url.absoluteString,
            display: "Scratch document — p. \(page)", page: page
        )
    }

    @Test("A missing embedded thumbnail is rendered from its exact granted page path")
    func rendersInkyPageToPNG() async throws {
        let fixture = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pdf = fixture.root.appendingPathComponent("scans/page.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeInkyPDF(to: pdf)

        let cache = fixture.root.appendingPathComponent("thumbnail-cache", isDirectory: true)
        let store = ReaderRootStore(defaults: scratchDefaults())
        #expect(store.grantRoot(fixture.root).marker?.guid == fixture.marker.guid)
        let renderer = SourceBlockThumbnailRenderer(
            rootStore: store, thumbnailer: PDFThumbnailer(cacheDirectory: cache)
        )

        let png = try #require(await renderer.png(for: anchor(marker: fixture.marker, relativePath: "scans/page.pdf")))
        let bitmap = try #require(NSBitmapImageRep(data: png))
        let centreColor = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2))
        let centre = try #require(centreColor.usingColorSpace(.deviceRGB))
        #expect(centre.redComponent < 0.25 && centre.greenComponent < 0.25 && centre.blueComponent < 0.25,
                "the center of the inky fixture must remain dark after the Notes fallback render")
    }

    @Test("The fallback never basename-walks or warms a cache for a missing exact path")
    func skipsRenamedCandidate() async throws {
        let fixture = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let renamed = fixture.root.appendingPathComponent("moved/page.pdf")
        try FileManager.default.createDirectory(at: renamed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeInkyPDF(to: renamed)

        let cache = fixture.root.appendingPathComponent("thumbnail-cache", isDirectory: true)
        let store = ReaderRootStore(defaults: scratchDefaults())
        #expect(store.grantRoot(fixture.root).marker?.guid == fixture.marker.guid)
        let renderer = SourceBlockThumbnailRenderer(
            rootStore: store, thumbnailer: PDFThumbnailer(cacheDirectory: cache)
        )

        let png = await renderer.png(for: anchor(marker: fixture.marker, relativePath: "claimed/page.pdf"))
        #expect(png == nil, "an untrusted rename must not trigger an archive-wide basename search")
        let cached = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        #expect(cached.isEmpty, "a refused exact path must not create a thumbnail cache entry")
    }

    @Test("The parsed durable-link page remains authoritative over pasted metadata")
    func skipsPageMetadataThatDisagreesWithTheLink() async throws {
        let fixture = try makeScratchRoot()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pdf = fixture.root.appendingPathComponent("scans/page.pdf")
        try FileManager.default.createDirectory(at: pdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeInkyPDF(to: pdf)

        let cache = fixture.root.appendingPathComponent("thumbnail-cache", isDirectory: true)
        let store = ReaderRootStore(defaults: scratchDefaults())
        #expect(store.grantRoot(fixture.root).marker?.guid == fixture.marker.guid)
        let renderer = SourceBlockThumbnailRenderer(
            rootStore: store, thumbnailer: PDFThumbnailer(cacheDirectory: cache)
        )
        var untrustedAnchor = anchor(marker: fixture.marker, relativePath: "scans/page.pdf", page: 1)
        untrustedAnchor.page = 2

        #expect(await renderer.png(for: untrustedAnchor) == nil)
        let cached = (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? []
        #expect(cached.isEmpty, "metadata that disagrees with the durable link must not warm the cache")
    }
}
