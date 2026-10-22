import AppKit
import XCTest
@testable import ArchiveReader

/// W40.fix-reader-long-name-overrun: a long file name drew past its Name column, across Type and the
/// tag chips. The layout guard cannot see it — the field's frame (and accessibility frame) is its cell;
/// only the pixels overflow, because views don't clip to bounds by default since macOS 14. So this
/// renders the real Name-cell formatter in a fixed-width cell inside a wider, transparent container and
/// asserts no ink lands to the right of the cell.
@MainActor
final class NameCellTruncationTests: XCTestCase {

    private static let longName = "00085 IMG — Memorandum to the Governor regarding the 1978 budget "
        + "revision and the attached correspondence from the Department of Finance.pdf"
    private static let cellWidth: CGFloat = 200
    private static let canvas = CGSize(width: 480, height: 44)

    func testLongNameStaysInsideItsColumn() throws {
        try assertNoInkPastCell(snippet: nil, artifact: "w40-long-name-single.png")
    }

    func testLongNameWithSearchSnippetStaysInsideItsColumn() throws {
        try assertNoInkPastCell(snippet: Self.snippet, artifact: "w40-long-name-snippet.png")
    }

    /// The bug as the VM shot shows it: inside a real `NSTableView` with automatic row heights, the
    /// field took the full width of its text and drew across the next columns. The fixed-width rig
    /// below cannot show that; this one lays out the table's own cells in the table's own columns.
    func testLongNameStaysInsideItsTableColumn() throws {
        for snippet in [nil, Self.snippet] as [[SearchSnippet.Segment]?] {
            let harness = NameColumnHarness(name: Self.longName, snippet: snippet)
            let scroll = harness.makeScrollView(size: CGSize(width: 760, height: 120))
            let table = try XCTUnwrap(scroll.documentView as? NSTableView)
            scroll.appearance = NSAppearance(named: .aqua)
            scroll.layoutSubtreeIfNeeded()
            let cellView = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true)
                                         as? NSTableCellView)
            table.layoutSubtreeIfNeeded()
            let tf = try XCTUnwrap(cellView.textField)
            let fieldInTable = table.convert(tf.bounds, from: tf)
            let nameColumn = table.rect(ofColumn: 0)
            XCTAssertLessThanOrEqual(fieldInTable.maxX, nameColumn.maxX + 0.5,
                                     "the name field is wider than its column (snippet: \(snippet != nil))")

            let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: scroll, size: scroll.frame.size))
            writeRenderArtifact(data, named: "w40-long-name-table-\(snippet == nil ? "single" : "snippet").png")
            let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
            let scale = CGFloat(image.width) / scroll.frame.width
            let rowRect = table.convert(table.rect(ofRow: 0), to: scroll)
            // CGImage rows run top-down; the scroll view is flipped-agnostic, so measure from its top.
            let top = scroll.isFlipped ? rowRect.minY : scroll.frame.height - rowRect.maxY
            let pastName = CGRect(x: (nameColumn.maxX + 1) * scale, y: top * scale,
                                  width: CGFloat(image.width) - (nameColumn.maxX + 1) * scale,
                                  height: rowRect.height * scale).integral
            let past = try XCTUnwrap(image.cropping(to: pastName))
            XCTAssertLessThan(PixelStats.from(cgImage: past).nonWhiteFraction, 0.001,
                              "the name drew into the columns past its own (snippet: \(snippet != nil))")
            let inName = try XCTUnwrap(image.cropping(to: CGRect(
                x: nameColumn.midX * scale, y: top * scale,
                width: nameColumn.width / 2 * scale, height: rowRect.height * scale).integral))
            XCTAssertGreaterThan(PixelStats.from(cgImage: inName).nonWhiteFraction, 0.01,
                                 "non-vacuity: the name must draw in its own column")
        }
    }

    private static let snippet: [SearchSnippet.Segment] = [
        .init(text: "…the budget for the coming year, page 3. ", isMatch: false),
        .init(text: "California", isMatch: true),
        .init(text: " archives and the records of the State Department of Finance", isMatch: false),
    ]

    private func assertNoInkPastCell(snippet: [SearchSnippet.Segment]?, artifact: String,
                                     file: StaticString = #filePath, line: UInt = #line) throws {
        let container = NSView(frame: CGRect(origin: .zero, size: Self.canvas))
        container.appearance = NSAppearance(named: .aqua)   // dark text, so the artifact is readable
        let cell = NSView(frame: CGRect(x: 0, y: 0, width: Self.cellWidth, height: Self.canvas.height))
        container.addSubview(cell)
        // The same field and constraints the table's text cells use (AppKitTableView `cell.<colID>`).
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingMiddle
        tf.cell?.truncatesLastVisibleLine = true
        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        AppKitTableView.Coordinator.configureNameTextField(
            tf, name: Self.longName, dotColor: .systemRed, disambiguator: nil,
            snippet: snippet, fontSize: 13
        )

        let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: container, size: Self.canvas),
                                 "the Name-cell formatter did not produce a bitmap", file: file, line: line)
        writeRenderArtifact(data, named: artifact)
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data), file: file, line: line)
        let scale = CGFloat(image.width) / Self.canvas.width
        let edge = Int((Self.cellWidth * scale).rounded(.up))

        // Non-vacuity: the name fills the far half of its cell (the colour dot alone sits at the left).
        let farHalf = try XCTUnwrap(image.cropping(
            to: CGRect(x: edge / 2, y: 0, width: edge - edge / 2, height: image.height)))
        XCTAssertLessThan(PixelStats.from(cgImage: farHalf).transparentFraction, 0.99,
                          "non-vacuity: the name must draw across its cell", file: file, line: line)

        let outside = try XCTUnwrap(image.cropping(
            to: CGRect(x: edge, y: 0, width: image.width - edge, height: image.height)))
        XCTAssertEqual(PixelStats.from(cgImage: outside).transparentFraction, 1, accuracy: 0.0001,
                       "the name drew past its column — it must truncate inside the cell",
                       file: file, line: line)
    }
}

/// A two-column table (Name, then an empty Type) configured like `AppKitTableView`'s, whose Name cells
/// come from the table's own cell factory and formatter.
@MainActor
private final class NameColumnHarness: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let name: String
    let snippet: [SearchSnippet.Segment]?

    init(name: String, snippet: [SearchSnippet.Segment]?) {
        self.name = name
        self.snippet = snippet
    }

    func makeScrollView(size: CGSize) -> NSScrollView {
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        let table = NSTableView()
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowHeight = 24
        table.usesAutomaticRowHeights = true
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.headerView = nil
        table.backgroundColor = .white
        for (id, width) in [("name", CGFloat(320)), ("type", CGFloat(56))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        table.reloadData()
        objc_setAssociatedObject(scroll, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)   // table.delegate is weak
        return scroll
    }

    private static var key: UInt8 = 0

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = AppKitTableView.Coordinator.makeTextCell(
            identifier: NSUserInterfaceItemIdentifier("cell.\(id)"))
        let tf = cell.textField!
        tf.font = NSFont.systemFont(ofSize: 13)
        if id == "name" {
            AppKitTableView.Coordinator.configureNameTextField(
                tf, name: name, dotColor: .systemRed, disambiguator: nil, snippet: snippet, fontSize: 13)
        } else {
            tf.stringValue = ""
        }
        return cell
    }
}
