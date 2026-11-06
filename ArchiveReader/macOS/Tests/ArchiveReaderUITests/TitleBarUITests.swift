import XCTest
import AppKit

/// W40.fix-reader-titlebar-gradient (reader-1 row 34): the title bar behind "Archive Reader" was split where the
/// sidebar meets the list, the sidebar's material on one side and the toolbar's on the other, with a gradient
/// between them. Read off the window's pixels, since the accessibility tree does not carry a background: a band
/// near the top of the title bar, clear of the traffic lights, the title and the toolbar buttons, must have one
/// luminance either side of the sidebar's edge, in light and dark. Screenshots: `[shot] titlebar-*`.
final class TitleBarUITests: FixtureUITestCase {

    /// The largest luminance step (0–1) allowed between columns of the band. Measured in the VM: see `[titlebar]`.
    private static let maxSpread = 0.02

    func testTitleBarIsEvenAcrossTheSidebarEdgeInLightMode() throws { try checkTitleBar(LayoutGuard.lightModeArguments, "light") }
    func testTitleBarIsEvenAcrossTheSidebarEdgeInDarkMode() throws { try checkTitleBar(LayoutGuard.darkModeArguments, "dark") }

    private func checkTitleBar(_ appearance: [String], _ name: String) throws {
        app.terminate()
        app.launchArguments += appearance
        app.launch()
        app.activate()
        let window = app.windows["Archive Reader"]
        XCTAssertTrue(table.waitForExistence(timeout: 10), "Table should appear after the relaunch")
        waitForRows(minimum: 1, timeout: 15)
        let divider = window.descendants(matching: .any)["ar.divider.sidebar"]
        XCTAssertTrue(divider.waitForExistence(timeout: 5), "The sidebar should be showing")
        RunLoop.current.run(until: Date().addingTimeInterval(1))   // let the window finish drawing
        _ = captureScreenshot("titlebar-\(name)")

        let frame = window.frame
        let edge = divider.frame.midX - frame.minX
        let shot = window.screenshot().image
        guard let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return XCTFail("No pixels for the window")
        }
        let scale = CGFloat(cg.width) / frame.width
        // 3–7 pt below the window's top edge, 90 pt either side of the sidebar's edge.
        let band = CGRect(x: max(100, edge - 90), y: 3, width: 180, height: 4)
            .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
        guard let crop = cg.cropping(to: band) else { return XCTFail("Band \(band) is outside the window") }
        let columns = Self.columnLuminances(crop)
        let spread = (columns.max() ?? 0) - (columns.min() ?? 0)
        print("[titlebar] \(name): edge \(edge) pt, band \(band) px, luminance \(String(format: "%.3f", columns.min() ?? 0))–"
              + "\(String(format: "%.3f", columns.max() ?? 0)), spread \(String(format: "%.3f", spread))")
        XCTAssertLessThanOrEqual(spread, Self.maxSpread,
                                 "The title bar's background changes across the sidebar's edge in \(name) appearance")
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
