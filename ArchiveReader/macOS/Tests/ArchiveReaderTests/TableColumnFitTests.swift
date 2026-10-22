import XCTest
import AppKit
@testable import ArchiveReader

/// W40.fix-reader-tagcloud-width — when the table loses width (the tag cloud opening beside it), File name and
/// File tags give it up and the narrow columns keep theirs, so Quality and Read stay on screen; closing the cloud
/// gives it back exactly. The table is built by `AppKitTableView.addColumns` and fitted by the same
/// `TableColumnFitter` the app uses, in a scroll view with no window (the unit host draws nothing); the fitter
/// follows the clip view's frame, which changes with the scroll view's whether or not a window is drawn.
@MainActor
final class TableColumnFitTests: XCTestCase {

    private var fitter: TableColumnFitter?

    /// Provenance hidden, as it is by default (`ProvenanceColumnTests`).
    private func makeTable(width: CGFloat) -> (NSScrollView, NSTableView) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        let tableView = NSTableView(frame: scrollView.bounds)
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        AppKitTableView.addColumns(to: tableView)
        tableView.tableColumns.first { $0.identifier.rawValue == "classification" }!.isHidden = true
        scrollView.documentView = tableView
        fitter = AppKitTableView.fitColumns(of: tableView)
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, tableView)
    }

    private func resize(_ scrollView: NSScrollView, to width: CGFloat) {
        scrollView.setFrameSize(NSSize(width: width, height: 600))
        scrollView.layoutSubtreeIfNeeded()
    }

    private func width(_ tableView: NSTableView, _ id: String) -> CGFloat {
        tableView.tableColumns.first { $0.identifier.rawValue == id }!.width
    }

    /// Every visible column's width plus the spacing between them: the width the rows need.
    private func needed(_ tableView: NSTableView) -> CGFloat {
        let visible = tableView.tableColumns.filter { !$0.isHidden }
        return visible.reduce(0) { $0 + $1.width } + CGFloat(visible.count) * tableView.intercellSpacing.width
    }

    func testOnlyNameAndTagsAreFlexible() {
        XCTAssertEqual(AppKitTableView.columnDefinitions.filter(\.flexible).map(\.id), ["name", "tags"])
    }

    func testWidthsShareTheShortfallByWhatEachCanGive() {
        // Fits: unchanged.
        XCTAssertEqual(TableColumnFitter.widths(preferred: [320, 300], minimums: [200, 160], available: 700), [320, 300])
        // 130 short; slack 120 and 140, so 60 and 70.
        XCTAssertEqual(TableColumnFitter.widths(preferred: [320, 300], minimums: [200, 160], available: 490), [260, 230])
        // More short than both can give: both at their minimums.
        XCTAssertEqual(TableColumnFitter.widths(preferred: [320, 300], minimums: [200, 160], available: 100), [200, 160])
        // A column already at its minimum gives nothing; the other gives it all.
        XCTAssertEqual(TableColumnFitter.widths(preferred: [200, 300], minimums: [200, 160], available: 400), [200, 200])
    }

    /// While the cut lasts the two columns fill exactly the whole points available, so as the sidebar slides in
    /// (the table's left edge moving right as fast as its width shrinks) Read's start does not wobble by a point.
    func testTheCutFillsExactlyTheWholePointsAvailable() {
        for tenths in stride(from: 6_190, through: 3_600, by: -7) {
            let available = CGFloat(tenths) / 10
            let w = TableColumnFitter.widths(preferred: [320, 300], minimums: [200, 160], available: available)
            XCTAssertEqual(w[0] + w[1], available.rounded(.down), "at \(available)")
            XCTAssertGreaterThanOrEqual(w[0], 200)
            XCTAssertGreaterThanOrEqual(w[1], 160)
        }
    }

    /// The 2026-10-16 reproduction: a 1400-pt window with its 210-pt sidebar, then the cloud's 240 pt and its
    /// divider taken from beside the list.
    func testOpeningTheCloudShrinksNameAndTagsNotQualityAndRead() {
        let (scrollView, tableView) = makeTable(width: 1_185)
        let fixed = ["flag", "warning", "date", "type", "quality", "read"]
        let before = Dictionary(uniqueKeysWithValues: fixed.map { ($0, width(tableView, $0)) })
        XCTAssertEqual(width(tableView, "name"), 320, "the full window fits the columns as built")
        XCTAssertEqual(width(tableView, "tags"), 300)

        for _ in 0..<3 {
            resize(scrollView, to: 1_185 - 241)
            for id in fixed { XCTAssertEqual(width(tableView, id), before[id]!, "\(id) should keep its width") }
            XCTAssertLessThan(width(tableView, "name"), 320)
            XCTAssertLessThan(width(tableView, "tags"), 300)
            XCTAssertLessThanOrEqual(needed(tableView), scrollView.contentSize.width,
                                     "the columns should fit beside the cloud, with Quality and Read on screen")

            resize(scrollView, to: 1_185)
            XCTAssertEqual(width(tableView, "name"), 320, "closing the cloud gives the width back")
            XCTAssertEqual(width(tableView, "tags"), 300)
            for id in fixed { XCTAssertEqual(width(tableView, id), before[id]!, "\(id) should keep its width") }
        }
    }

    /// Past what the flexible columns can give (both at their minimums), the table scrolls sideways rather than
    /// squeezing Quality or Read below theirs.
    func testNarrowerThanTheMinimumsStopsAtTheMinimums() {
        let (scrollView, tableView) = makeTable(width: 1_185)
        resize(scrollView, to: 500)
        XCTAssertEqual(width(tableView, "name"), 200)
        XCTAssertEqual(width(tableView, "tags"), 160)
        XCTAssertEqual(width(tableView, "quality"), 80)
        XCTAssertEqual(width(tableView, "read"), 84)
    }

    /// A width the user drags File name to is what it returns to, not the width it was built with.
    func testAUserDragSetsThePreferredWidth() {
        let (scrollView, tableView) = makeTable(width: 1_185)
        tableView.tableColumns.first { $0.identifier.rawValue == "name" }!.width = 250   // as a drag ends
        resize(scrollView, to: 800)
        resize(scrollView, to: 1_185)
        XCTAssertEqual(width(tableView, "name"), 250)
        XCTAssertEqual(width(tableView, "tags"), 300)
    }

    /// Showing Provenance takes its width from the flexible columns too.
    func testShowingAColumnRefits() {
        let (scrollView, tableView) = makeTable(width: 1_000)
        tableView.tableColumns.first { $0.identifier.rawValue == "classification" }!.isHidden = false
        fitter?.fit()
        XCTAssertLessThanOrEqual(needed(tableView), scrollView.contentSize.width)
    }

    /// A File tags cell narrowed until its tokens wrap asks for a taller row; the VM layout guard saw a second
    /// line of tokens drawn below a 20-pt row at 160 and 214 pt.
    func testWrappedTagsAskForATallerCell() {
        func height(atWidth width: CGFloat) -> CGFloat {
            let cell = TagTokenCellView(frame: NSRect(x: 0, y: 0, width: width, height: 20))
            cell.tokenField.font = .systemFont(ofSize: 13)
            cell.tokenField.objectValue = ["Economics", "1983", "Agricultural Labor Relations", "Brown", "Budget"]
            cell.layoutSubtreeIfNeeded()
            return cell.fittingSize.height
        }
        let wide = height(atWidth: 900), narrow = height(atWidth: 160)
        XCTAssertGreaterThan(wide, 0)
        XCTAssertGreaterThan(narrow, wide * 1.5, "five tags in 160 pt wrap, so the cell should be taller (\(narrow) vs \(wide))")
    }
}
