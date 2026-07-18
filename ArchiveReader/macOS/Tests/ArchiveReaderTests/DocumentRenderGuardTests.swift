// DocumentRenderGuardTests.swift — headless "did it actually render?" guards.
//
// These exercise the same rendering path the Reader uses to show archival documents
// (ArchiveCore's `PDFThumbnailer`, which draws a PDF page to a bitmap) and assert on the
// *pixels*, not the accessibility tree. They guard the shared 2-page PDF SPEC — page 0 = the
// scanned image, page 1 = the OCR text layer — which is the one contract that is genuinely
// dangerous to get wrong and which no `app.staticTexts[...].exists` assertion can protect:
// a document viewer that renders a blank grey rectangle passes every accessibility check.
//
// All headless: no app launch, no XCUITest runner, no TCC/Accessibility/automation prompt —
// so this runs in the autonomous health-gate, unlike the XCUITest bundles.

import XCTest
import SwiftUI
import PDFKit
import AppKit
import CoreGraphics
import ArchiveCore

final class DocumentRenderGuardTests: XCTestCase {

    // MARK: page-0 image page renders (the core SPEC guard)

    func testScanImagePageRendersNonBlank() async throws {
        let pdf = try makeTwoPagePDF()
        let thumbnailer = PDFThumbnailer(cacheDirectory: makeTempDir("thumbs"))

        // page: 1 (1-based) == page index 0 == the scanned image page in the 2-page SPEC.
        let rendered = await thumbnailer.png(fileURL: pdf, page: 1,
                                             linkKey: "archivereader://test/two-page", mtime: Date())
        let png = try XCTUnwrap(
            rendered,
            "PDFThumbnailer returned nil for the image page — the render pipeline degraded"
        )
        writeRenderArtifact(png, named: "scan-image-page.png")

        let cg = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png), "thumbnail PNG did not decode")
        let stats = try XCTUnwrap(assertRendersNonBlank(cg, "scan image page (page 0)"))
        // A scanned page fills most of the frame — demand substantial ink, not just a stray pixel.
        XCTAssertGreaterThan(stats.nonWhiteFraction, 0.10,
                             "image page has almost no ink (\(stats.nonWhiteFraction)) — likely a blank/failed render")
    }

    // MARK: page-1 OCR text page renders

    func testOCRTextPageRendersNonBlank() async throws {
        let pdf = try makeTwoPagePDF()
        let thumbnailer = PDFThumbnailer(cacheDirectory: makeTempDir("thumbs"))

        let rendered = await thumbnailer.png(fileURL: pdf, page: 2,
                                             linkKey: "archivereader://test/two-page", mtime: Date())
        let png = try XCTUnwrap(rendered)
        writeRenderArtifact(png, named: "ocr-text-page.png")
        let cg = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png))
        let stats = try XCTUnwrap(assertRendersNonBlank(cg, "OCR text page (page 1)"))
        // A full page of OCR text carries substantial ink — lock in a margin well clear of the
        // 0.01 blank threshold so system-font metric / font-smoothing differences (e.g. a
        // headless AppleFontSmoothing=0 gate) can't spuriously flip the guard.
        XCTAssertGreaterThan(stats.nonWhiteFraction, 0.03,
                             "OCR text page has too little ink (\(stats.nonWhiteFraction)) — fixture or render regressed")
    }

    // MARK: the guard actually discriminates (a guard that never fails is worthless)

    func testTrulyBlankPageIsFlaggedBlank() async throws {
        let pdf = try makeBlankPDF()
        let thumbnailer = PDFThumbnailer(cacheDirectory: makeTempDir("thumbs"))

        let rendered = await thumbnailer.png(fileURL: pdf, page: 1,
                                             linkKey: "archivereader://test/blank", mtime: Date())
        let png = try XCTUnwrap(rendered)
        let cg = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png))
        let stats = PixelStats.from(cgImage: cg)
        XCTAssertTrue(stats.isEffectivelyBlank(),
                      "an all-white page must be flagged blank; nonWhite=\(stats.nonWhiteFraction)")
    }

    // MARK: a uniform field of ANY colour is blank (the "blank grey/black rectangle" gap)

    func testUniformFieldIsFlaggedBlankRegardlessOfColour() throws {
        // A viewer that degrades to a flat grey/black placeholder is 100% non-white yet drew
        // nothing meaningful. nonWhiteFraction alone can't catch it — luminanceSpread must.
        for gray in [0.0, 0.55, 1.0] {   // black, mid-grey, white
            let stats = PixelStats.from(cgImage: solidCGImage(gray: gray))
            XCTAssertTrue(stats.isEffectivelyBlank(),
                          "uniform field (gray=\(gray)) must be flagged blank; "
                          + "spread=\(stats.luminanceSpread) nonWhite=\(stats.nonWhiteFraction)")
        }
        // Control: a two-tone (high-contrast) image is NOT blank.
        let contrast = PixelStats.from(cgImage: solidCGImage(gray: 0.5, topHalfGray: 0.0))
        XCTAssertFalse(contrast.isEffectivelyBlank(),
                       "a high-contrast image must not be flagged blank; spread=\(contrast.luminanceSpread)")
    }

    // MARK: general SwiftUI-view render path (the reusable "see any view" tool)

    @MainActor
    func testSwiftUIViewRendersViaImageRenderer() throws {
        // A pure colour + shape view: deterministic, no font dependence.
        let view = ZStack {
            Color(red: 0.15, green: 0.35, blue: 0.75)
            Circle().fill(.white).frame(width: 60, height: 60)
        }
        let data = try XCTUnwrap(RenderProbe.pngData(from: view, size: CGSize(width: 200, height: 120)),
                                 "ImageRenderer produced no image")
        writeRenderArtifact(data, named: "swiftui-view.png")
        let cg = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        let stats = try XCTUnwrap(assertRendersNonBlank(cg, "SwiftUI view"))
        XCTAssertGreaterThan(stats.nonWhiteFraction, 0.5,
                             "a mostly-coloured view should be far from white (\(stats.nonWhiteFraction))")
    }

    // MARK: - Fixtures

    private func makeTempDir(_ prefix: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// A 2-page PDF mirroring the SPEC: page 0 = a dense drawn "scan", page 1 = an OCR text layer.
    private func makeTwoPagePDF() throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 520)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = pageRect
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))

        // Page 0 — simulate a scanned image: mid-grey field with black blocks (lots of ink).
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor(white: 0.55, alpha: 1).cgColor)
        ctx.fill(pageRect.insetBy(dx: 16, dy: 16))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 48, y: 400, width: 304, height: 44))
        ctx.fill(CGRect(x: 48, y: 90, width: 304, height: 220))
        ctx.endPDFPage()

        // Page 1 — the OCR text layer: a full page of text, representative of a real OCR page and
        // robustly above the blank threshold regardless of system-font metrics / smoothing.
        ctx.beginPDFPage(nil)
        let paragraph = String(repeating: "Sample OCR text — page two of the two-page format. ", count: 14)
        drawText(paragraph, into: ctx, rect: pageRect, fontSize: 18)
        ctx.endPDFPage()

        ctx.closePDF()
        return try writePDF(data, name: "two-page")
    }

    /// A single all-white page — the "rendered nothing" control case.
    private func makeBlankPDF() throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 400, height: 520)
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        var box = pageRect
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(pageRect)
        ctx.endPDFPage()
        ctx.closePDF()
        return try writePDF(data, name: "blank")
    }

    private func drawText(_ string: String, into ctx: CGContext, rect: CGRect, fontSize: CGFloat = 16) {
        let attr = NSAttributedString(string: string,
                                      attributes: [.font: NSFont.systemFont(ofSize: fontSize)])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let path = CGPath(rect: rect.insetBy(dx: 24, dy: 24), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
        CTFrameDraw(frame, ctx)
    }

    /// A solid (or two-tone) RGBA8 image, built directly — no PDF/thumbnail antialiasing to flake on.
    /// `topHalfGray`, when set, fills the top half a different shade (a deterministic high-contrast control).
    private func solidCGImage(width: Int = 80, height: Int = 100, gray: Double, topHalfGray: Double? = nil) -> CGImage {
        let bytesPerRow = width * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: bytesPerRow, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let base = CGFloat(gray)
        ctx.setFillColor(red: base, green: base, blue: base, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let top = topHalfGray {
            let t = CGFloat(top)
            ctx.setFillColor(red: t, green: t, blue: t, alpha: 1)
            ctx.fill(CGRect(x: 0, y: height / 2, width: width, height: height - height / 2))
        }
        return ctx.makeImage()!
    }

    private func writePDF(_ data: NSData, name: String) throws -> URL {
        let url = makeTempDir("pdf").appendingPathComponent("\(name).pdf")
        try (data as Data).write(to: url, options: .atomic)
        return url
    }
}
