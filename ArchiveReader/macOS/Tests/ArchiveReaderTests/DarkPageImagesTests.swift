// DarkPageImagesTests.swift — W40.reader-image-invert: Invert Image Colors draws the page images dark, paper near black
// and ink near white with its hue kept, in the image pane and the page tiles; the file is never changed. The pane's
// filter is a Core Animation layer filter, which `cacheDisplay` does not draw, so here the filter itself is run on a
// scan-like picture and the pane is checked to carry it; the VM's InvertImagesUITests reads the composited window.

import XCTest
import PDFKit
import AppKit
import SwiftUI
@testable import ArchiveReader

@MainActor
final class DarkPageImagesTests: XCTestCase {

    /// A photographed page: grey paper (0.72), black type (0.15) and a purple ditto line.
    private func scan() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 60, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.72, green: 0.71, blue: 0.68, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 60, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.45, green: 0.30, blue: 0.70, alpha: 1))
        context.fill(CGRect(x: 40, y: 0, width: 20, height: 20))
        return try XCTUnwrap(context.makeImage())
    }

    /// The sRGB colour at a column of the picture's middle row, 0…1.
    private func colour(_ image: CGImage, x: Int) throws -> (r: Double, g: Double, b: Double) {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let i = ((height / 2) * width + x) * 4
        return (Double(pixels[i]) / 255, Double(pixels[i + 1]) / 255, Double(pixels[i + 2]) / 255)
    }

    func testTheMappingTurnsTheLightnessAndKeepsTheHue() {
        let paper = DarkPageImages.map(0.72, 0.71, 0.68)
        XCTAssertLessThan(max(paper.0, paper.1, paper.2), 0.3, "grey paper goes dark")
        let ink = DarkPageImages.map(0.15, 0.15, 0.15)
        XCTAssertGreaterThan(min(ink.0, ink.1, ink.2), 0.8, "black type goes near white")
        let white = DarkPageImages.map(1, 1, 1), black = DarkPageImages.map(0, 0, 0)
        XCTAssertEqual(white.0, DarkPageImages.darkest, accuracy: 0.001, "white is kept off pure black")
        XCTAssertEqual(black.0, DarkPageImages.lightest, accuracy: 0.001, "black is kept off pure white")
        let purple = DarkPageImages.map(0.45, 0.30, 0.70)
        XCTAssertGreaterThan(purple.2, purple.0, "purple ink stays blue-red, not green")
        XCTAssertGreaterThan(purple.0, purple.1)
        let red = DarkPageImages.map(0.75, 0.25, 0.25)
        XCTAssertGreaterThan(red.0, red.1 + 0.3, "a red stamp stays red")
    }

    /// The filter is applied on sRGB values: in Core Image's linear light the grey paper would come out light.
    func testTheFilterDarkensAScanAndLeavesItsSourceAlone() throws {
        let source = try scan()
        let before = try colour(source, x: 10)
        let dark = DarkPageImages.darkened(source)
        XCTAssertEqual(dark.width, source.width)
        let paper = try colour(dark, x: 10), ink = try colour(dark, x: 30), purple = try colour(dark, x: 50)
        XCTAssertLessThan(max(paper.r, paper.g, paper.b), 0.3, "the paper is drawn dark: \(paper)")
        XCTAssertGreaterThan(min(ink.r, ink.g, ink.b), 0.75, "the type is drawn near white: \(ink)")
        XCTAssertGreaterThan(purple.b, purple.g + 0.15, "the ditto ink keeps its hue: \(purple)")
        XCTAssertGreaterThan(purple.r, purple.g, "the ditto ink keeps its hue: \(purple)")
        let after = try colour(source, x: 10)
        XCTAssertEqual(before.r, after.r, "the source picture is not changed")
        XCTAssertTrue(DarkPageImages.darkened(source) === dark, "a redraw reuses the picture")
    }

    /// The image pane carries the filter while the setting is on, behind the page the grey that draws darkest, and
    /// no shadow; off, it is the pane it was. The switch reaches a pane already on screen, without a new view.
    func testThePaneCarriesTheFilterOnlyWhileOn() throws {
        let controller = PDFPaneController(key: "left", persists: false)
        let page = try XCTUnwrap(PDFPage(image: NSImage(cgImage: try scan(), size: NSSize(width: 600, height: 200))))
        let host = NSHostingView(rootView: PDFPaneView(page: page, controller: controller, inverted: true))
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let on = try XCTUnwrap(controller.pdfView, "the pane should have made its PDFView")
        XCTAssertEqual(on.contentFilters.count, 1, "the pane is filtered")
        XCTAssertEqual(on.contentFilters.first?.name, "CIColorCubeWithColorSpace")
        XCTAssertEqual(on.backgroundColor, .white, "white behind the page draws as the darkest grey")
        XCTAssertFalse(on.pageShadowsEnabled)

        host.rootView = PDFPaneView(page: page, controller: controller, inverted: false)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let off = try XCTUnwrap(controller.pdfView)
        XCTAssertTrue(off === on, "the same pane is switched")
        XCTAssertTrue(off.contentFilters.isEmpty, "off, nothing is filtered")
        XCTAssertEqual(off.backgroundColor, PDFPaneView.paneBackground)
        XCTAssertTrue(off.pageShadowsEnabled)
    }

    /// A page tile under the setting is drawn dark (a render guard: the SwiftUI view to pixels).
    func testATileDrawsDark() throws {
        let image = PageImage(cgImage: try scan())
        func mean(_ inverted: Bool) throws -> Double {
            let label = PageThumbnailLabel(image: image, label: "PDF page 1", selected: false, finished: true,
                                           height: 120, inverted: inverted)
            let png = try XCTUnwrap(RenderProbe.pngData(from: label, size: CGSize(width: 240, height: 140)))
            if inverted { writeRenderArtifact(png, named: "w40-image-invert-tile.png") }
            let picture = try XCTUnwrap(RenderProbe.cgImage(fromPNG: png))
            let middle = try XCTUnwrap(picture.cropping(to: CGRect(x: picture.width / 12, y: picture.height * 2 / 5,
                                                                   width: 40, height: 20)))
            return try colour(middle, x: 20).g
        }
        let plain = try mean(false), dark = try mean(true)
        XCTAssertGreaterThan(plain, 0.6, "the plain tile shows grey paper")
        XCTAssertLessThan(dark, 0.25, "the inverted tile shows the paper dark")
    }

    func testTheCommandIsInTheTable() {
        XCTAssertEqual(ReaderCommand.invertImages.key, CommandKey("i", [.command, .control]))
        XCTAssertEqual(ReaderCommand.invertImages.context, .menuBar)
        XCTAssertTrue(ReaderCommand.invertImages.help.contains("not changed"))
    }
}
