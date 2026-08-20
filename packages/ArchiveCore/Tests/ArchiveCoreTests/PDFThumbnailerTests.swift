// PDFThumbnailerTests.swift — render scratch PDFs, cache hit/miss, eviction, degrade
import Testing
import Foundation
import PDFKit
import AppKit
@testable import ArchiveCore

// MARK: - ThumbnailCacheKey

@Suite("ThumbnailCacheKey")
struct ThumbnailCacheKeyTests {

    @Test func filenameIsDeterministic() {
        let a = ThumbnailCacheKey.filename(
            linkKey: "archivereader://reveal?root=abc&rel=doc.pdf",
            page: 1, mtime: Date(timeIntervalSince1970: 1000),
            pointWidth: 220, scale: 2
        )
        let b = ThumbnailCacheKey.filename(
            linkKey: "archivereader://reveal?root=abc&rel=doc.pdf",
            page: 1, mtime: Date(timeIntervalSince1970: 1000),
            pointWidth: 220, scale: 2
        )
        #expect(a == b)
        #expect(a.hasSuffix(".png"))
    }

    @Test func differentPageProducesDifferentKey() {
        let a = ThumbnailCacheKey.filename(
            linkKey: "x", page: 1, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 220, scale: 2
        )
        let b = ThumbnailCacheKey.filename(
            linkKey: "x", page: 2, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 220, scale: 2
        )
        #expect(a != b)
    }

    @Test func differentMtimeProducesDifferentKey() {
        let a = ThumbnailCacheKey.filename(
            linkKey: "x", page: 1, mtime: Date(timeIntervalSince1970: 100),
            pointWidth: 220, scale: 2
        )
        let b = ThumbnailCacheKey.filename(
            linkKey: "x", page: 1, mtime: Date(timeIntervalSince1970: 200),
            pointWidth: 220, scale: 2
        )
        #expect(a != b)
    }

    @Test func differentSpecProducesDifferentKey() {
        let a = ThumbnailCacheKey.filename(
            linkKey: "x", page: 1, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 220, scale: 2
        )
        let b = ThumbnailCacheKey.filename(
            linkKey: "x", page: 1, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 300, scale: 2
        )
        #expect(a != b)
    }

    @Test func differentLinkKeyProducesDifferentKey() {
        let a = ThumbnailCacheKey.filename(
            linkKey: "archivereader://reveal?root=abc&rel=doc.pdf",
            page: 1, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 220, scale: 2
        )
        let b = ThumbnailCacheKey.filename(
            linkKey: "archivereader://reveal?root=def&rel=doc.pdf",
            page: 1, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 220, scale: 2
        )
        #expect(a != b)
    }

    @Test func keyIsHexPlusPng() {
        let key = ThumbnailCacheKey.filename(
            linkKey: "test", page: 1, mtime: Date(timeIntervalSince1970: 0),
            pointWidth: 220, scale: 2
        )
        // SHA256 hex = 64 chars + ".png" = 68 chars
        #expect(key.count == 68)
        let hex = String(key.dropLast(4))
        #expect(hex.allSatisfy { $0.isHexDigit })
    }
}

// MARK: - PDFThumbnailer

@Suite("PDFThumbnailer")
struct PDFThumbnailerTests {

    /// Creates a scratch 2-page PDF in a temp directory and returns (pdfURL, tempDir).
    private func makeScratchPDF() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFThumbTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let doc = PDFDocument()

        // Page 1: a simple colored rect drawn into an NSImage
        let img1 = NSImage(size: NSSize(width: 200, height: 300))
        img1.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 300).fill()
        img1.unlockFocus()
        if let page1 = PDFPage(image: img1) {
            doc.insert(page1, at: 0)
        }

        // Page 2: different color
        let img2 = NSImage(size: NSSize(width: 200, height: 300))
        img2.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 300).fill()
        img2.unlockFocus()
        if let page2 = PDFPage(image: img2) {
            doc.insert(page2, at: 1)
        }

        let pdfURL = dir.appendingPathComponent("test.pdf")
        doc.write(to: pdfURL)
        return (pdfURL, dir)
    }

    private func makeCacheDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFThumbCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a scratch page whose halves let the renderer test orientation, not merely non-blank output.
    private func makeOrientationPDF() throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFThumbOrientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let image = NSImage(size: NSSize(width: 100, height: 200))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 100).fill()
        NSColor.red.setFill()
        NSRect(x: 0, y: 100, width: 100, height: 100).fill()
        image.unlockFocus()

        let document = PDFDocument()
        guard let page = PDFPage(image: image) else { throw CocoaError(.fileWriteUnknown) }
        document.insert(page, at: 0)
        let pdfURL = dir.appendingPathComponent("orientation.pdf")
        guard document.write(to: pdfURL) else { throw CocoaError(.fileWriteUnknown) }
        return (pdfURL, dir)
    }

    private func redMinusBlue(_ rep: NSBitmapImageRep, yFraction: CGFloat) -> CGFloat? {
        guard let color = rep.colorAt(x: rep.pixelsWide / 2, y: Int(CGFloat(rep.pixelsHigh) * yFraction))?
                .usingColorSpace(.deviceRGB) else {
            return nil
        }
        return color.redComponent - color.blueComponent
    }

    @Test func rendersPage1ToPNG() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let data = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://page1", mtime: Date()
        )

        #expect(data != nil)
        // Verify it's valid PNG (starts with PNG magic bytes)
        if let data {
            #expect(data.count > 8)
            let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47] // \x89PNG
            let header = Array(data.prefix(4))
            #expect(header == magic)
        }
    }

    @Test func rendersPage2ToPNG() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let data = await thumbnailer.png(
            fileURL: pdfURL, page: 2,
            linkKey: "test://page2", mtime: Date()
        )

        #expect(data != nil)
    }

    @Test func preservesPDFKitThumbnailOrientation() async throws {
        let (pdfURL, tempDir) = try makeOrientationPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let spec = PDFThumbnailer.Spec(pointWidth: 100, scale: 1)
        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        guard let actualData = await thumbnailer.png(
            fileURL: pdfURL, page: 1, spec: spec, linkKey: "test://orientation", mtime: Date()
        ), let actualRep = NSBitmapImageRep(data: actualData),
              let expectedDocument = PDFDocument(url: pdfURL),
              let page = expectedDocument.page(at: 0) else {
            Issue.record("thumbnail renderer unexpectedly degraded")
            return
        }

        let expected = page.thumbnail(of: NSSize(width: 100, height: 200), for: .cropBox)
        guard let expectedTIFF = expected.tiffRepresentation,
              let expectedRep = NSBitmapImageRep(data: expectedTIFF),
              let expectedTop = redMinusBlue(expectedRep, yFraction: 0.75),
              let expectedBottom = redMinusBlue(expectedRep, yFraction: 0.25),
              let actualTop = redMinusBlue(actualRep, yFraction: 0.75),
              let actualBottom = redMinusBlue(actualRep, yFraction: 0.25) else {
            Issue.record("could not sample rendered thumbnail pixels")
            return
        }

        #expect(expectedTop * expectedBottom < 0, "fixture must distinguish top from bottom")
        #expect(actualTop * expectedTop > 0, "top half must retain PDFKit's orientation")
        #expect(actualBottom * expectedBottom > 0, "bottom half must retain PDFKit's orientation")
    }

    @Test func cacheHitReturnsSameData() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let mtime = Date()
        let first = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://hit", mtime: mtime
        )
        #expect(first != nil)

        // Second call should hit the disk cache (same key)
        let second = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://hit", mtime: mtime
        )
        #expect(second == first)
    }

    @Test func mtimeChangeInvalidatesCache() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let first = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://mtime", mtime: Date(timeIntervalSince1970: 1000)
        )
        #expect(first != nil)

        // Different mtime = different cache key = re-render
        let second = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://mtime", mtime: Date(timeIntervalSince1970: 2000)
        )
        #expect(second != nil)

        // Both should be valid PNG but from different cache entries
        // (We can verify two files exist in the cache dir)
        let files = try FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        #expect(files.count >= 2)
    }

    @Test func returnsNilForOutOfRangePage() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let data = await thumbnailer.png(
            fileURL: pdfURL, page: 99,
            linkKey: "test://oor", mtime: Date()
        )
        #expect(data == nil)
    }

    @Test func returnsNilForZeroPage() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let data = await thumbnailer.png(
            fileURL: pdfURL, page: 0,
            linkKey: "test://zero", mtime: Date()
        )
        #expect(data == nil)
    }

    @Test func returnsNilForNonexistentFile() async throws {
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let bogusURL = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID()).pdf")
        let data = await thumbnailer.png(
            fileURL: bogusURL, page: 1,
            linkKey: "test://bogus", mtime: Date()
        )
        #expect(data == nil)
    }

    @Test func evictsWhenOverBudget() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Tiny budget so one thumbnail should trigger eviction of the other
        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir, diskBudgetBytes: 1)

        let _ = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://evict1", mtime: Date()
        )
        let _ = await thumbnailer.png(
            fileURL: pdfURL, page: 2,
            linkKey: "test://evict2", mtime: Date()
        )

        // With a 1-byte budget, after the second write eviction should have pruned
        // down to at most 1 file (the most recent)
        let files = try FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "png" }
        #expect(files.count <= 1)
    }

    @Test func diskCacheFileIsWritten() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let mtime = Date(timeIntervalSince1970: 5000)
        let _ = await thumbnailer.png(
            fileURL: pdfURL, page: 1,
            linkKey: "test://disk", mtime: mtime
        )

        // The expected cache file should exist
        let expectedName = ThumbnailCacheKey.filename(
            linkKey: "test://disk", page: 1, mtime: mtime,
            pointWidth: 220, scale: 2
        )
        let cacheFile = cacheDir.appendingPathComponent(expectedName)
        #expect(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test func specDefaultValues() {
        let spec = PDFThumbnailer.Spec()
        #expect(spec.pointWidth == 220)
        #expect(spec.scale == 2)
    }

    @Test func customSpecAffectsRender() async throws {
        let (pdfURL, tempDir) = try makeScratchPDF()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let cacheDir = try makeCacheDir()
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let thumbnailer = PDFThumbnailer(cacheDirectory: cacheDir)
        let mtime = Date()
        let smallSpec = PDFThumbnailer.Spec(pointWidth: 50, scale: 1)
        let largeSpec = PDFThumbnailer.Spec(pointWidth: 400, scale: 2)

        let small = await thumbnailer.png(
            fileURL: pdfURL, page: 1, spec: smallSpec,
            linkKey: "test://spec", mtime: mtime
        )
        let large = await thumbnailer.png(
            fileURL: pdfURL, page: 1, spec: largeSpec,
            linkKey: "test://spec", mtime: mtime
        )

        #expect(small != nil)
        #expect(large != nil)
        // Larger spec should produce more bytes
        if let small, let large {
            #expect(large.count > small.count)
        }
    }
}
