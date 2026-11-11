import AppKit
import XCTest

/// W40.fix-notes-titlebar-label (notes-2 row 3), as the Reader's W40.fix-reader-titlebar-gradient: on macOS 27 the
/// title bar behind "Archive Notes" was grey over the folder list and white to its right. Read off the window's
/// pixels, since the accessibility tree does not carry a background: a band near the top of the title bar, clear of
/// the traffic lights, the title and the toolbar, must have one luminance either side of the folder list's edge, in
/// light and dark. The toolbar's "Notes" label, which ran to the edge of its pill, is in the shots
/// (`[shot] titlebar-*`), looked at rather than asserted.
final class TitleBarUITests: NotesFixtureUITestCase {

    /// The largest luminance step (0–1) allowed between columns of the band (the Reader's bound).
    private static let maxSpread = 0.02

    private var dark = false
    override var extraLaunchArguments: [String] { dark ? LayoutGuard.darkModeArguments : LayoutGuard.lightModeArguments }

    func testTitleBarIsEvenAcrossTheFolderListEdgeInLightMode() throws {
        try withFixture { checkTitleBar("light") }
    }

    func testTitleBarIsEvenAcrossTheFolderListEdgeInDarkMode() throws {
        dark = true
        try withFixture { checkTitleBar("dark") }
    }

    private func checkTitleBar(_ name: String) {
        let divider = mainWindow.descendants(matching: .any)["an.divider.tree"].firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 10), "The folder list should be showing")
        XCTAssertTrue(mainWindow.descendants(matching: .any)["an.toolbar.windowKind"].firstMatch.exists,
                      "The toolbar should name the window")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // let the window finish drawing

        let frame = mainWindow.frame
        let edge = divider.frame.midX - frame.minX
        let shot = mainWindow.screenshot()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("uitest-titlebar-\(name).png")
        do {
            try shot.pngRepresentation.write(to: url, options: .atomic)
            print("[shot] titlebar-\(name): wrote \(url.path)")
        } catch {
            print("[shot] titlebar-\(name): could not write \(url.path) — \(error)")
        }
        guard let cg = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("No pixels for the window")
        }
        let scale = CGFloat(cg.width) / frame.width
        // 3–7 pt below the window's top edge, 90 pt either side of the folder list's edge.
        let band = CGRect(x: max(100, edge - 90), y: 3, width: 180, height: 4)
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        guard let crop = cg.cropping(to: band) else { return XCTFail("Band \(band) is outside the window") }
        let columns = Self.columnLuminances(crop)
        let spread = (columns.max() ?? 0) - (columns.min() ?? 0)
        print("[titlebar] \(name): edge \(edge) pt, band \(band) px, luminance \(String(format: "%.3f", columns.min() ?? 0))–"
              + "\(String(format: "%.3f", columns.max() ?? 0)), spread \(String(format: "%.3f", spread))")
        XCTAssertLessThanOrEqual(spread, Self.maxSpread,
                                 "The title bar's background changes across the folder list's edge in \(name) appearance")
    }

    /// The mean luminance (0–1) of each pixel column.
    private static func columnLuminances(_ image: CGImage) -> [Double] {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<w).map { x in
            var sum = 0.0
            for y in 0..<h {
                let i = (y * w + x) * 4
                sum += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
            }
            return sum / Double(h) / 255
        }
    }
}
