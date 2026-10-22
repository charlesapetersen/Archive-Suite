import AppKit
import ArchiveCore
import XCTest
@testable import ArchiveReader

/// W40.fix-reader-selected-row-contrast: on a selected row the Read column's accent-blue "Unread" and the pale
/// tag chips merged into the selection highlight (worst in dark). The layout guard cannot see colour, so this
/// lays the Reader's own Read and File tags cells out in a real `NSTableView`, selects the row with emphasis,
/// renders it headlessly and measures the WCAG contrast of the label and of each chip against the row.
@MainActor
final class SelectedRowContrastTests: XCTestCase {

    private static let subjects = ["Jerry Brown", "Economics", "1983"]
    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    /// WCAG's floor for large text. Before the fix the accent label measured about 1.7 on the selection; white
    /// measures about 6.
    private static let floor = 3.0

    func testUnreadAndChipsReadOnASelectedRow() throws {
        for (name, appearance) in Self.appearances {
            let harness = SelectedRowHarness(subjects: Self.subjects, readState: .unread)
            let scroll = harness.makeScrollView(size: CGSize(width: 420, height: 60), appearance: appearance,
                                                selected: true)
            let table = try XCTUnwrap(scroll.documentView as? NSTableView)
            let readCell = try XCTUnwrap(harness.readCell)
            let tagCell = try XCTUnwrap(harness.tagCell)

            let (image, scale) = try render(scroll, artifact: "w40-selected-row-\(name).png")
            // The row view hands its cells the emphasized style as it draws, so these hold for the pixels above.
            let rowView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: false))
            XCTAssertTrue(rowView.isSelected && rowView.isEmphasized, "\(name): the row should be selected with emphasis")
            XCTAssertEqual(readCell.backgroundStyle, .emphasized, "\(name): the selected row should emphasize its cells")
            XCTAssertTrue(tagCell.tokenField.isEmphasized, "\(name): the field should know its row is selected")
            let field = tagCell.tokenField
            XCTAssertGreaterThanOrEqual(field.bounds.height + 0.01,
                                        TagChips.layout(field.chipTitles, font: field.font!, width: field.bounds.width).height,
                                        "\(name): one line of chips must fit the row's field (\(field.bounds.height) pt)")

            let label = try XCTUnwrap(readCell.textField)
            let labelContrast = try measure(image, rect: label.bounds, in: label, scroll: scroll, scale: scale)
            print("[W40.selrow] \(name) selected, Unread: \(labelContrast)")
            XCTAssertGreaterThan(labelContrast.ratio, Self.floor, "\(name): Unread on the selection: \(labelContrast)")
            // The selection must have drawn behind it, or an accent label on an unselected row would pass.
            XCTAssert((0.02...0.5).contains(labelContrast.background),
                      "\(name): the row behind the label is not the selection highlight: \(labelContrast)")

            for (chip, contrast) in try chipContrasts(image, cell: tagCell, scroll: scroll, scale: scale) {
                print("[W40.selrow] \(name) selected, chip \(chip.title): \(contrast)")
                XCTAssertGreaterThan(contrast.ratio, Self.floor, "\(name): chip \(chip.title) on the selection: \(contrast)")
                XCTAssert((0.02...0.5).contains(contrast.background),
                          "\(name): chip \(chip.title) is not on the selection highlight: \(contrast)")
            }
        }
    }

    /// An ordinary row keeps readable chips (the title on the tinted fill) and the accent label on the row.
    func testUnreadAndChipsReadOnAnOrdinaryRow() throws {
        for (name, appearance) in Self.appearances {
            let harness = SelectedRowHarness(subjects: Self.subjects, readState: .unread)
            let scroll = harness.makeScrollView(size: CGSize(width: 420, height: 60), appearance: appearance,
                                                selected: false)
            let readCell = try XCTUnwrap(harness.readCell)
            let tagCell = try XCTUnwrap(harness.tagCell)

            let (image, scale) = try render(scroll, artifact: "w40-ordinary-row-\(name).png")
            XCTAssertEqual(readCell.backgroundStyle, .normal, "\(name): an unselected row's cells are normal")
            XCTAssertFalse(tagCell.tokenField.isEmphasized)
            let label = try XCTUnwrap(readCell.textField)
            let labelContrast = try measure(image, rect: label.bounds, in: label, scroll: scroll, scale: scale)
            print("[W40.selrow] \(name) ordinary, Unread: \(labelContrast)")
            XCTAssertGreaterThan(labelContrast.ratio, Self.floor, "\(name): Unread on an ordinary row: \(labelContrast)")
            for (chip, contrast) in try chipContrasts(image, cell: tagCell, scroll: scroll, scale: scale) {
                print("[W40.selrow] \(name) ordinary, chip \(chip.title): \(contrast)")
                XCTAssertGreaterThan(contrast.ratio, Self.floor, "\(name): chip \(chip.title) on its fill: \(contrast)")
            }
        }
    }

    /// Non-vacuity: the measure must fail the label the Reader used to draw, the accent on the selection.
    func testProbeFailsTheAccentLabelOnTheSelection() throws {
        for (name, appearance) in Self.appearances {
            let size = CGSize(width: 120, height: 24)
            let container = NSView(frame: CGRect(origin: .zero, size: size))
            container.appearance = NSAppearance(named: appearance)
            container.wantsLayer = true
            let box = NSBox(frame: container.bounds)
            box.boxType = .custom
            box.borderWidth = 0
            box.fillColor = .selectedContentBackgroundColor
            container.addSubview(box)
            let label = NSTextField(labelWithString: "Unread")
            label.font = .systemFont(ofSize: 13)
            label.textColor = .controlAccentColor
            label.cell?.backgroundStyle = .emphasized
            label.frame = CGRect(x: 4, y: 3, width: 100, height: 18)
            container.addSubview(label)

            let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: container, size: size))
            writeRenderArtifact(data, named: "w40-accent-on-selection-\(name).png")
            let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
            let scale = CGFloat(image.width) / size.width
            let top = container.isFlipped ? label.frame.minY : size.height - label.frame.maxY
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: label.frame.minX * scale, y: top * scale,
                                                               width: label.frame.width * scale,
                                                               height: label.frame.height * scale).integral))
            let contrast = try XCTUnwrap(InkContrast.measure(crop))
            print("[W40.selrow] \(name) the old accent label on the selection: \(contrast)")
            XCTAssertLessThan(contrast.ratio, Self.floor,
                              "\(name): the probe must fail the accent label on the selection: \(contrast)")
        }
    }

    /// One line of the Reader's chips is as tall as one line of native tokens, within a point, at the list text
    /// sizes the Options offer, so drawing the chips does not change a row's height. (A selection cannot change
    /// it either: `TagChips.layout` takes no state.)
    func testChipsKeepTheNativeRowHeight() {
        for size in [10, 13, 16, 20] as [CGFloat] {
            let cell = TagTokenCellView(frame: NSRect(x: 0, y: 0, width: 900, height: 20))
            cell.tokenField.font = .systemFont(ofSize: size)
            cell.tokenField.objectValue = Self.subjects
            let native = cell.tokenField.height(editing: true, width: 896)
            let chips = cell.tokenField.height(editing: false, width: 896)
            XCTAssertEqual(chips, native, accuracy: 1, "at \(size) pt: chips \(chips), native tokens \(native)")
        }
    }

    /// The chips flow and wrap at the field's width, never overlap, clamp a chip wider than the field, and keep
    /// one line for the placeholder.
    func testChipLayoutWrapsAndClamps() {
        let font = NSFont.systemFont(ofSize: 13)
        let titles = ["Economics", "1983", "Agricultural Labor Relations", "Brown", "Budget"]
        let wide = TagChips.layout(titles, font: font, width: 900)
        XCTAssertEqual(wide.chips.count, titles.count)
        XCTAssertEqual(Set(wide.chips.map { $0.frame.minY }).count, 1, "five chips fit one line at 900 pt")
        let narrow = TagChips.layout(titles, font: font, width: 160)
        XCTAssertGreaterThan(narrow.height, wide.height * 1.5, "five chips in 160 pt wrap: \(narrow.height) vs \(wide.height)")
        for chip in narrow.chips {
            XCTAssertLessThanOrEqual(chip.frame.maxX, 160, "\(chip.title) runs past the field")
            XCTAssertLessThanOrEqual(chip.frame.maxY, narrow.height, "\(chip.title) runs below the layout's height")
        }
        for (i, a) in narrow.chips.enumerated() {
            for b in narrow.chips.dropFirst(i + 1) {
                XCTAssertFalse(a.frame.intersects(b.frame), "\(a.title) and \(b.title) overlap")
            }
        }
        let clamped = TagChips.layout(["A subject far wider than the whole field is, by a long way"], font: font, width: 120)
        XCTAssertEqual(clamped.chips.first?.frame.width, 120 - TagChips.leadingInset)
        XCTAssertEqual(TagChips.layout([], font: font, width: 300).height,
                       TagChips.chipHeight(for: font) + 2 * TagChips.verticalInset)
    }

    // MARK: - Helpers

    private func render(_ scroll: NSScrollView, artifact: String) throws -> (CGImage, CGFloat) {
        let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: scroll, size: scroll.frame.size))
        writeRenderArtifact(data, named: artifact)
        let image = try XCTUnwrap(RenderProbe.cgImage(fromPNG: data))
        return (image, CGFloat(image.width) / scroll.frame.width)
    }

    /// The contrast inside `rect` (in `view`'s coordinates) of the rendered `scroll`.
    private func measure(_ image: CGImage, rect: CGRect, in view: NSView, scroll: NSScrollView,
                         scale: CGFloat) throws -> InkContrast {
        let r = scroll.convert(rect, from: view)
        let top = scroll.isFlipped ? r.minY : scroll.frame.height - r.maxY
        let pixels = CGRect(x: r.minX * scale, y: top * scale, width: r.width * scale, height: r.height * scale).integral
        let crop = try XCTUnwrap(image.cropping(to: pixels), "crop \(pixels) out of \(image.width)×\(image.height)")
        return try XCTUnwrap(InkContrast.measure(crop), "too small a crop to measure: \(pixels)")
    }

    /// Every chip's contrast, each measured inside the frame `TagChips` laid it out in.
    private func chipContrasts(_ image: CGImage, cell: TagTokenCellView, scroll: NSScrollView,
                               scale: CGFloat) throws -> [(TagChips.Chip, InkContrast)] {
        let field = cell.tokenField
        let layout = TagChips.layout(field.chipTitles, font: try XCTUnwrap(field.font), width: field.bounds.width)
        XCTAssertEqual(layout.chips.count, Self.subjects.count)
        return try layout.chips.map { chip in
            // The layout is top-down; the field may not be flipped.
            let viewRect = field.isFlipped ? chip.frame
                : CGRect(x: chip.frame.minX, y: field.bounds.height - chip.frame.maxY,
                         width: chip.frame.width, height: chip.frame.height)
            return (chip, try measure(image, rect: viewRect, in: field, scroll: scroll, scale: scale))
        }
    }
}

/// A one-row table with the Reader's Read and File tags cells, from the table's own cell factory and
/// configuration, selected with emphasis the way a key window's table selects.
@MainActor
private final class SelectedRowHarness: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    /// Headless, `cacheDisplay` renders what the views draw but not the row view's own selection highlight (seen
    /// 2026-10-22: emphasized cells on a plain row background), so this row view paints the system's highlight
    /// colour for its state itself. Its selection and emphasis, and the cells' background style, are the table's.
    final class HighlightingRowView: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            guard isSelected else { return }
            (isEmphasized ? NSColor.selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor).setFill()
            bounds.fill()
        }
    }

    let subjects: [String]
    let readState: ReadState?
    private(set) var readCell: TintedTextCellView?
    private(set) var tagCell: TagTokenCellView?

    init(subjects: [String], readState: ReadState?) {
        self.subjects = subjects
        self.readState = readState
    }

    func makeScrollView(size: CGSize, appearance: NSAppearance.Name, selected: Bool) -> NSScrollView {
        let scroll = NSScrollView(frame: CGRect(origin: .zero, size: size))
        scroll.appearance = NSAppearance(named: appearance)
        let table = NSTableView()
        table.style = .plain
        // The app measures its rows automatically, which off-window gives the table's whole height instead; 21 pt
        // is what its rows measure at 13 pt (a label and its 2-pt margins), so the chips have to fit a real row.
        table.rowHeight = 21
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.headerView = nil
        table.allowsMultipleSelection = true
        for (id, width) in [("read", CGFloat(84)), ("tags", CGFloat(300))] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        scroll.documentView = table
        scroll.drawsBackground = true
        table.reloadData()
        objc_setAssociatedObject(scroll, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)   // table.delegate is weak
        scroll.layoutSubtreeIfNeeded()
        if selected {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            // Headless there is no key window to emphasize the selection; the row view is told as a window would.
            table.rowView(atRow: 0, makeIfNecessary: true)?.isEmphasized = true
        }
        scroll.layoutSubtreeIfNeeded()
        return scroll
    }

    private static var key: UInt8 = 0

    func numberOfRows(in tableView: NSTableView) -> Int { 1 }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        HighlightingRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch tableColumn?.identifier.rawValue {
        case "read":
            let cell = AppKitTableView.Coordinator.makeTextCell(identifier: NSUserInterfaceItemIdentifier("cell.read"))
            cell.textField?.font = .systemFont(ofSize: 13)
            AppKitTableView.Coordinator.configureReadStateCell(cell, state: readState)
            readCell = cell
            return cell
        case "tags":
            let cell = TagTokenCellView()
            cell.identifier = NSUserInterfaceItemIdentifier("cell.tags.token")
            cell.tokenField.font = .systemFont(ofSize: 13)
            cell.tokenField.objectValue = subjects
            tagCell = cell
            return cell
        default:
            return nil
        }
    }
}
