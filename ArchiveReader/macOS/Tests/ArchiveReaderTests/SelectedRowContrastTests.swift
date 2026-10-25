import AppKit
import ArchiveCore
import XCTest
@testable import ArchiveReader

/// W40.fix-reader-selected-row-contrast: on a selected row the Read column's accent-blue "Unread" and the pale
/// tag chips merged into the selection highlight (worst in dark). The layout guard cannot see colour, so this
/// lays the Reader's own Read and File tags cells out in a real `NSTableView`, selects the row with emphasis,
/// renders it headlessly and measures the WCAG contrast of the label and of each chip against the row.
///
/// What each should measure is worked out from the system colours of the appearance (the selected-row text colour
/// on the selection colour, primary text on the row). Small text must clear 4.5:1 in every row state.
@MainActor
final class SelectedRowContrastTests: XCTestCase {

    private static let subjects = ["Jerry Brown", "Economics", "1983"]
    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    /// WCAG AA for the Reader's small labels, including the chips.
    private static let floor = 4.5

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
            XCTAssertGreaterThanOrEqual(field.bounds.height + 0.01, field.chipsLayout(width: field.bounds.width).height,
                                        "\(name): one line of chips must fit the row's field (\(field.bounds.height) pt)")

            let expected = expectedContrast(.alternateSelectedControlTextColor, over: .selectedContentBackgroundColor,
                                            in: appearance)
            let label = try XCTUnwrap(readCell.textField)
            let labelContrast = try measure(image, rect: label.bounds, in: label, scroll: scroll, scale: scale)
            print("[W40.selrow] \(name) selected, Unread: \(labelContrast); system pair \(expected)")
            assertContrast(labelContrast, expected: expected, "\(name): Unread on the selection")
            // The selection must have drawn behind it, or an accent label on an unselected row would pass.
            XCTAssertEqual(labelContrast.background, luminance(.selectedContentBackgroundColor, in: appearance),
                           accuracy: 0.02, "\(name): the row behind the label is not the selection highlight")

            for chip in try chipContrasts(image, cell: tagCell, scroll: scroll, scale: scale) {
                print("[W40.selrow] \(name) selected, chip \(chip.title): outline \(chip.whole); title \(chip.text)")
                assertContrast(chip.whole, expected: expected, "\(name): chip \(chip.title), outline on the selection")
                assertContrast(chip.text, expected: expected, "\(name): chip \(chip.title), title on the selection")
            }
        }
    }

    /// Reuse the same cells as emphasis/selection changes, with both read states using AA text colours.
    func testReadStatesAndChipsFollowSelectionChanges() throws {
        for (name, appearance) in Self.appearances {
            for state in [ReadState.read, .unread] {
                let harness = SelectedRowHarness(subjects: Self.subjects, readState: state)
                let scroll = harness.makeScrollView(size: CGSize(width: 420, height: 60), appearance: appearance,
                                                    selected: false)
                let table = try XCTUnwrap(scroll.documentView as? NSTableView)
                let row = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
                let cell = try XCTUnwrap(harness.readCell)
                let tags = try XCTUnwrap(harness.tagCell)
                for (phase, selected, emphasized) in [("active", true, true), ("inactive", true, false),
                                                      ("ordinary", false, false), ("inactive-again", true, false),
                                                      ("active-again", true, true)] {
                    table.selectRowIndexes(selected ? IndexSet(integer: 0) : [], byExtendingSelection: false)
                    row.isEmphasized = emphasized
                    row.needsDisplay = true
                    let (image, scale) = try render(scroll, artifact: "w40-\(name)-\(state.rawValue)-\(phase).png")
                    XCTAssertEqual(cell.backgroundStyle, emphasized ? .emphasized : .normal)
                    XCTAssertEqual(tags.tokenField.isEmphasized, emphasized)
                    let label = try XCTUnwrap(cell.textField)
                    let contrast = try measure(image, rect: label.bounds, in: label, scroll: scroll, scale: scale)
                    print("[W40.selrow] \(name) \(state.rawValue) \(phase): \(contrast)")
                    let background: NSColor = selected
                        ? (emphasized ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
                        : .controlBackgroundColor
                    XCTAssertEqual(contrast.background, luminance(background, in: appearance), accuracy: 0.02)
                    // NSTextField resolves semantic labelColor in its own background style; its pixels can be
                    // more opaque than resolving the bare NSColor outside a text field. Assert the actual ink.
                    XCTAssertGreaterThanOrEqual(contrast.ratio, Self.floor, "\(name) \(state.rawValue) \(phase)")
                    for chip in try chipContrasts(image, cell: tags, scroll: scroll, scale: scale) {
                        let expected = emphasized
                            ? expectedContrast(.alternateSelectedControlTextColor, over: background, in: appearance)
                            : expectedContrast(.labelColor, over: TagChips.fill, over: background, in: appearance)
                        assertContrast(chip.text, expected: expected, "\(name) \(phase) chip \(chip.title)")
                    }
                }
            }
        }
    }

    /// An ordinary row keeps readable chips (the title on the tinted fill) and primary Unread text on the row.
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
            XCTAssertGreaterThanOrEqual(labelContrast.ratio, Self.floor)

            let chipExpected = expectedContrast(.labelColor, over: TagChips.fill, over: .controlBackgroundColor,
                                                in: appearance)
            for chip in try chipContrasts(image, cell: tagCell, scroll: scroll, scale: scale) {
                print("[W40.selrow] \(name) ordinary, chip \(chip.title): \(chip.text); system pair \(chipExpected)")
                assertContrast(chip.text, expected: chipExpected, "\(name): chip \(chip.title), title on its fill")
            }
        }
    }

    /// The same table/text-field drawing path used by Type and the warning glyph, including inactive rows.
    /// The warning is sampled as text too: the small triangle must meet the stronger 4.5:1 text floor.
    func testTypeAndWarningReadInEveryRowState() throws {
        for (name, appearance) in Self.appearances {
            for (title, tint) in [("PDF", ReaderColors.informationalCellTint),
                                  ("⚠", ReaderColors.warningCellTint)] {
                let harness = SelectedRowHarness(subjects: Self.subjects, readState: .read)
                let scroll = harness.makeScrollView(size: CGSize(width: 420, height: 60), appearance: appearance,
                                                    selected: false)
                let table = try XCTUnwrap(scroll.documentView as? NSTableView)
                let row = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: true))
                let cell = try XCTUnwrap(harness.readCell)
                let label = try XCTUnwrap(cell.textField)
                label.stringValue = title
                cell.tint = tint
                for (phase, selected, emphasized) in [("ordinary", false, false), ("active", true, true),
                                                      ("inactive", true, false), ("ordinary-again", false, false)] {
                    table.selectRowIndexes(selected ? IndexSet(integer: 0) : [], byExtendingSelection: false)
                    row.isEmphasized = emphasized
                    row.needsDisplay = true
                    let (image, scale) = try render(scroll, artifact: "w40-aa-\(name)-\(title)-\(phase).png")
                    let contrast = try measure(image, rect: label.bounds, in: label, scroll: scroll, scale: scale)
                    print("[W40.aa] \(name) \(title) \(phase): \(contrast)")
                    XCTAssertGreaterThanOrEqual(contrast.ratio, Self.floor)
                }
            }
        }
    }

    /// Non-vacuity: the measure must fail the label the Reader used to draw, the accent on the selection.
    func testProbeFailsTheAccentLabelOnTheSelection() throws {
        for (name, appearance) in Self.appearances {
            let expected = expectedContrast(.controlAccentColor, over: .selectedContentBackgroundColor, in: appearance)
            try XCTSkipIf(expected >= Self.floor, "\(name): this accent reads on its own selection (\(expected))")
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

    /// One line of the Reader's chips is exactly as tall as one line of native tokens at the list text sizes the
    /// Options offer, so drawing the chips changes no row's height and starting to edit moves nothing by a point.
    /// (A selection cannot change it either: `TagChips.layout` takes no state.)
    func testChipsKeepTheNativeRowHeight() {
        for size in [10, 13, 16, 20] as [CGFloat] {
            let cell = TagTokenCellView(frame: NSRect(x: 0, y: 0, width: 900, height: 20))
            cell.tokenField.font = .systemFont(ofSize: size)
            cell.tokenField.objectValue = Self.subjects
            let native = cell.tokenField.height(editing: true, width: 896)
            let chips = cell.tokenField.height(editing: false, width: 896)
            XCTAssertEqual(chips, native, accuracy: 0.01, "at \(size) pt: chips \(chips), native tokens \(native)")
            XCTAssertGreaterThan(chips, size, "at \(size) pt a line of chips should be taller than the text")
        }
    }

    /// A row is measured before its field has a width, as one line; once laid out, a field whose chips wrap asks
    /// the table to measure the row again, and asks once. A field whose chips fit asks for nothing.
    func testACellTooShortForItsChipsAsksForItsRowHeightAgainOnce() throws {
        let wrapping = ["Economics", "1983", "Agricultural Labor Relations", "Brown", "Budget", "Legislative Analyst"]
        for (subjects, expectedNotes) in [(wrapping, [0]), (Self.subjects, [])] {
            let harness = SelectedRowHarness(subjects: subjects, readState: .read)
            let scroll = harness.makeScrollView(size: CGSize(width: 420, height: 60), appearance: .aqua, selected: false)
            let table = try XCTUnwrap(scroll.documentView as? RecordingTableView)
            let field = try XCTUnwrap(harness.tagCell).tokenField
            let needed = field.chipsLayout(width: field.bounds.width).height
            XCTAssertEqual(needed > field.bounds.height, !expectedNotes.isEmpty,
                           "\(subjects.count) tags in \(field.bounds.width) pt need \(needed) pt of \(field.bounds.height)")
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // the cell re-notes on the next turn
            scroll.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(table.notedRows, expectedNotes, "\(subjects.count) tags: rows asked to be measured again")
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

    private struct ChipContrast {
        let title: String
        /// Over the chip's whole frame: on a selected row the outline is the ink.
        let whole: InkContrast
        /// Over the title's rect alone, inside the padding: the lettering is the ink.
        let text: InkContrast
    }

    /// Every chip's contrast, each measured inside the frame the field laid it out in.
    private func chipContrasts(_ image: CGImage, cell: TagTokenCellView, scroll: NSScrollView,
                               scale: CGFloat) throws -> [ChipContrast] {
        let field = cell.tokenField
        let layout = field.chipsLayout(width: field.bounds.width)
        XCTAssertEqual(layout.chips.count, Self.subjects.count)
        let padding = TagChips.horizontalPadding(for: try XCTUnwrap(field.font))
        return try layout.chips.map { chip in
            let whole = try measure(image, rect: viewRect(chip.frame, in: field), in: field, scroll: scroll, scale: scale)
            let text = try measure(image, rect: viewRect(chip.frame.insetBy(dx: padding, dy: 2), in: field),
                                   in: field, scroll: scroll, scale: scale)
            return ChipContrast(title: chip.title, whole: whole, text: text)
        }
    }

    /// `TagChips` lays out top-down; the field may not be flipped.
    private func viewRect(_ topDown: CGRect, in view: NSView) -> CGRect {
        view.isFlipped ? topDown
            : CGRect(x: topDown.minX, y: view.bounds.height - topDown.maxY, width: topDown.width, height: topDown.height)
    }

    /// A selected label or chip must match its explicit system pair and clear AA.
    /// The ink is sampled from antialiased glyphs, whose edges never reach the pure colour, so a thin dark title on
    /// a pale chip reads up to about a tenth below its pair (9.9 against 10.9, light); the measure may fall short of
    /// the pair by 15 % but never exceed it by more than 8 %.
    private func assertContrast(_ measured: InkContrast, expected: Double, _ what: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssert((expected * 0.85 - 0.5...expected * 1.08 + 0.5).contains(measured.ratio),
                  "\(what): \(measured), the system pair measures \(expected)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(measured.ratio, Self.floor, "\(what): \(measured)", file: file, line: line)
    }

    /// The WCAG contrast of `ink` drawn over `background` (each composited by its own alpha, `background` first
    /// over `base`), as the appearance resolves the colours. Quartz blends in the bitmap's gamma-encoded space, as
    /// this does, before linearising.
    private func expectedContrast(_ ink: NSColor, over background: NSColor, over base: NSColor? = nil,
                                  in appearance: NSAppearance.Name) -> Double {
        let bg = luminance(background, over: base, in: appearance)
        return InkContrast.ratio(luminance(ink, over: background, over: base, in: appearance), bg)
    }

    private func luminance(_ color: NSColor, over background: NSColor? = nil, over base: NSColor? = nil,
                           in appearance: NSAppearance.Name) -> Double {
        var result = 0.0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            func rgb(_ c: NSColor) -> (Double, Double, Double, Double) {
                let s = c.usingColorSpace(.sRGB)!
                return (Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent), Double(s.alphaComponent))
            }
            func composite(_ top: (Double, Double, Double, Double), over bottom: (Double, Double, Double)) -> (Double, Double, Double) {
                (top.3 * top.0 + (1 - top.3) * bottom.0, top.3 * top.1 + (1 - top.3) * bottom.1, top.3 * top.2 + (1 - top.3) * bottom.2)
            }
            var stack: (Double, Double, Double) = (1, 1, 1)
            if let base { let b = rgb(base); stack = (b.0, b.1, b.2) }
            if let background { stack = composite(rgb(background), over: stack) }
            let c = composite(rgb(color), over: stack)
            result = InkContrast.relativeLuminance(red: c.0, green: c.1, blue: c.2)
        }
        return result
    }
}

/// An `NSTableView` that records which rows were asked to be measured again.
@MainActor
private final class RecordingTableView: NSTableView {
    private(set) var notedRows: [Int] = []
    override func noteHeightOfRows(withIndexesChanged indexSet: IndexSet) {
        notedRows += indexSet
        super.noteHeightOfRows(withIndexesChanged: indexSet)
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
        let table = RecordingTableView()
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
