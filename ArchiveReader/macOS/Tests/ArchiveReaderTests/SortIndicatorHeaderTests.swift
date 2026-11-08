import XCTest
import AppKit
@testable import ArchiveReader

/// Real compact headers at the narrow-window fit. Native headers failed the direction comparison.
@MainActor
final class SortIndicatorHeaderTests: XCTestCase {
    func testIconHeadersRenderBothSortDirections() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 668, height: 200))
            let table = NSTableView(frame: scroll.bounds)
            table.style = .plain
            table.appearance = NSAppearance(named: appearance)
            table.intercellSpacing = NSSize(width: 8, height: 2)
            let header = ColumnPickerHeaderView(frame: NSRect(x: 0, y: 0, width: 668, height: 24))
            header.appearance = table.appearance
            table.headerView = header
            AppKitTableView.addColumns(to: table)
            table.tableColumns.first { $0.identifier.rawValue == "classification" }!.isHidden = true
            scroll.documentView = table
            let fitter = AppKitTableView.fitColumns(of: table)
            fitter.fit()
            for id in ["flag", "warning"] {
                let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == id })
                XCTAssertEqual(column.width, column.minWidth)
                var crops: [Data] = []
                for ascending in [true, false] {
                    table.sortDescriptors = [NSSortDescriptor(key: column.sortDescriptorPrototype!.key, ascending: ascending)]
                    header.needsDisplay = true
                    let data = try XCTUnwrap(RenderProbe.pngData(
                        fromAppKitView: header, size: CGSize(width: 668, height: 24)))
                    let name = "sort-header-\(id)-\(ascending ? "ascending" : "descending")-\(appearance.rawValue)"
                    writeRenderArtifact(data, named: name + ".png")
                    let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
                    let frame = header.headerRect(ofColumn: table.column(withIdentifier: column.identifier))
                    let scale = CGFloat(image.width) / header.bounds.width
                    let crop = try XCTUnwrap(image.cropping(to: CGRect(
                        x: frame.minX * scale, y: 0, width: frame.width * scale, height: CGFloat(image.height))))
                    let caret = try XCTUnwrap(crop.cropping(to: CGRect(
                        x: CGFloat(crop.width) - 12 * scale, y: 0,
                        width: 12 * scale, height: CGFloat(crop.height))))
                    crops.append(try XCTUnwrap(RenderProbe.pngData(from: caret)))
                    // The first 20 pt contain the icon, before the caret: sorting must not hide the glyph.
                    let icon = try XCTUnwrap(crop.cropping(to: CGRect(
                        x: 0, y: 0, width: 20 * scale, height: CGFloat(crop.height))))
                    // Header bitmaps can be transparent. Composite onto the theme's background before
                    // the nonblank guard, which otherwise treats opaque black ink alone as a uniform field.
                    let canvas = try XCTUnwrap(CGContext(
                        data: nil, width: icon.width, height: icon.height, bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    let bounds = CGRect(x: 0, y: 0, width: icon.width, height: icon.height)
                    canvas.setFillColor((appearance == .aqua ? NSColor.white : .black).cgColor)
                    canvas.fill(bounds)
                    canvas.draw(icon, in: bounds)
                    _ = assertRendersNonBlank(canvas.makeImage(), name + " icon")
                }
                XCTAssertNotEqual(crops[0], crops[1], "\(id) must visibly distinguish ascending and descending")
            }
        }
    }
}
