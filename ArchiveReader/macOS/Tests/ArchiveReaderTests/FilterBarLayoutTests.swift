import AppKit
import SwiftUI
import XCTest
@testable import ArchiveReader

/// W40.fix-reader-narrow-window — the filter bar's row math (`FilterBarLayout.rows`). The bar used to be an
/// `HStack` whose minimum was the sum of its controls, wider than the window's content column at 900 pt.
/// W40.fix-reader-filter-focus — and its text fields survive Save/Clear appearing (`ViewThatFits` rebuilt them).
@MainActor
final class FilterBarLayoutTests: XCTestCase {
    typealias Item = FilterBarLayout.Item

    private func rows(_ items: [Item], _ width: CGFloat) -> [[FilterBarLayout.Placed]] {
        FilterBarLayout.rows(items, width: width, spacing: 10)
    }

    func testEverythingFitsOnOneRowAndFieldsGrowToTheirIdeal() {
        let r = rows([Item(min: 100, ideal: 100), Item(min: 50, ideal: 120)], 400)
        XCTAssertEqual(r, [[.init(index: 0, x: 0, width: 100), .init(index: 1, x: 110, width: 120)]])
    }

    func testSpareWidthGoesToIdealsBeforeMaximums() {
        let r = rows([Item(min: 50, ideal: 60, max: 200), Item(min: 50, ideal: 100)], 220)
        // 110 spare (220 less the 10-pt gap): 10 to the first's ideal, 50 to the second's, the last 50 toward
        // the first's maximum.
        XCTAssertEqual(r.first?.map(\.width), [110, 100])
    }

    func testAControlThatDoesNotFitMovesToTheNextRow() {
        let r = rows([Item(min: 200, ideal: 200), Item(min: 150, ideal: 150), Item(min: 100, ideal: 100)], 380)
        XCTAssertEqual(r.map { $0.map(\.index) }, [[0, 1], [2]])
        for row in r { XCTAssertLessThanOrEqual(row.map { $0.x + $0.width }.max()!, 380) }
    }

    func testRowsBreakOnMinimumsNotIdeals() {
        // Ideals sum past the width, minimums do not: one row, each squeezed to fit.
        let r = rows([Item(min: 100, ideal: 200), Item(min: 100, ideal: 200)], 250)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].map(\.width).reduce(0, +) + 10, 250)
    }

    func testTrailingControlsSitAgainstTheRightEdgeInOrder() {
        let r = rows([Item(min: 100, ideal: 100), Item(min: 60, ideal: 60, trailing: true),
                      Item(min: 40, ideal: 40, trailing: true)], 400)
        XCTAssertEqual(r, [[.init(index: 0, x: 0, width: 100), .init(index: 1, x: 290, width: 60),
                            .init(index: 2, x: 360, width: 40)]])
    }

    func testAControlWiderThanTheBarGetsARowOfItsOwn() {
        let r = rows([Item(min: 50, ideal: 50), Item(min: 500, ideal: 500), Item(min: 50, ideal: 50)], 300)
        XCTAssertEqual(r.map { $0.map(\.index) }, [[0], [1], [2]])
    }

    // MARK: identity (W40.fix-reader-filter-focus)

    private final class Bar: ObservableObject { @Published var active = false; @Published var text = "" }

    private struct Wrapped: View {
        @ObservedObject var bar: Bar
        var body: some View {
            FilterBarLayout(spacing: 12) {
                TextField("Filter file name…", text: $bar.text).frame(minWidth: 90, maxWidth: 160)
                TextField("Search OCR text…", text: .constant("")).frame(minWidth: 100, maxWidth: 180)
                if bar.active {
                    Button("Save as Smart Folder") {}.fixedSize().filterBarTrailing()
                    Button("Clear") {}.fixedSize().filterBarTrailing()
                }
            }
        }
    }

    /// main's bar until this fix, reduced: one-row and two-row copies of the same fields
    private struct Switching: View {
        @ObservedObject var bar: Bar
        var body: some View {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { fields; Spacer(); trailing }
                VStack(alignment: .leading) { HStack(spacing: 12) { fields }; HStack { Spacer(); trailing } }
            }
        }
        @ViewBuilder private var fields: some View {
            TextField("Filter file name…", text: $bar.text).frame(minWidth: 90, maxWidth: 160)
            TextField("Search OCR text…", text: .constant("")).frame(minWidth: 100, maxWidth: 180)
        }
        @ViewBuilder private var trailing: some View { if bar.active { Button("Save as Smart Folder") {}; Button("Clear") {} } }
    }

    /// The fields' instances before and after Save/Clear appear in the view `make` builds, at `width` pt.
    private func fieldsAcrossTheButtons<V: View>(_ make: (Bar) -> V, width: CGFloat) -> ([ObjectIdentifier], [ObjectIdentifier]) {
        let bar = Bar()
        let host = NSHostingView(rootView: make(bar))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 80)
        host.layoutSubtreeIfNeeded()
        let before = editableFields(host).map(ObjectIdentifier.init)
        bar.active = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        return (before, editableFields(host).map(ObjectIdentifier.init))
    }

    private func editableFields(_ v: NSView) -> [NSTextField] {
        v.subviews.flatMap { s -> [NSTextField] in
            ((s as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []) + editableFields(s)
        }
    }

    /// The layout's own guarantee; NavigationWindowView's `filterBar` is what uses it. 300 pt holds the two fields
    /// on one row but not the buttons as well, so they wrap; the fields must be the same NSTextFields afterwards,
    /// or the one being typed in has lost the keyboard. On 21 Oct 2026 the same check of main's `ViewThatFits` bar
    /// found new instances at 300 and 420 pt (and the same at 600).
    func testTextFieldsKeepTheirIdentityWhenTheTrailingButtonsAppear() {
        for width in [300.0, 420.0, 600.0] {
            let (before, after) = fieldsAcrossTheButtons({ Wrapped(bar: $0) }, width: width)
            XCTAssertEqual(before.count, 2, "both fields are on screen at \(width) pt")
            XCTAssertEqual(after, before, "the fields were rebuilt at \(width) pt when Save/Clear appeared")
        }
        // The control: the same check sees ViewThatFits rebuild them, so the update did reach the view and the
        // check can tell a rebuild (SwiftUI draws the buttons itself, so there is no NSButton to look for).
        let (before, after) = fieldsAcrossTheButtons({ Switching(bar: $0) }, width: 300)
        XCTAssertEqual(before.count, 2)
        XCTAssertNotEqual(after, before, "ViewThatFits kept the fields at 300 pt: the check no longer sees a rebuild")
    }
}
