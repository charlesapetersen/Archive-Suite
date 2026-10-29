import AppKit
import SwiftUI
import XCTest
@testable import ArchiveNotes

@MainActor
final class PanelDividerAccessibilityTests: XCTestCase {
    func testVoiceOverResizesTheSameWidthWithinTheDragLimits() {
        var width = 210.0
        let divider = PanelDividerView()
        divider.size = Binding(get: { width }, set: { width = $0 })
        divider.range = 140...350

        XCTAssertEqual(divider.accessibilityRole(), .splitter)
        XCTAssertEqual(divider.accessibilityOrientation(), .vertical)
        XCTAssertEqual(divider.accessibilityMinValue() as? Double, 140)
        XCTAssertEqual(divider.accessibilityMaxValue() as? Double, 350)
        XCTAssertTrue(divider.accessibilityPerformIncrement())
        XCTAssertEqual(width, 220)
        XCTAssertEqual(divider.accessibilityValue() as? Double, width)
        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertEqual(width, 210)

        divider.setAccessibilityValue(1000)
        XCTAssertEqual(width, 350)
        XCTAssertTrue(divider.accessibilityPerformIncrement())
        XCTAssertEqual(width, 350)
        divider.setAccessibilityValue(-10)
        XCTAssertEqual(width, 140)
        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertEqual(width, 140)

        for invalid in [Double.nan, .infinity, -.infinity] {
            divider.setAccessibilityValue(invalid)
            XCTAssertEqual(width, 140, "an invalid AX value must never become a panel width")
        }
        divider.setAccessibilityValue("invalid")
        XCTAssertEqual(width, 140)
    }

    /// W48.notes-stacked-layout: the stacked layout's divider is the same splitter, oriented horizontally, and
    /// sets the list height inside its range.
    func testStackedDividerIsAHorizontalSplitterOverTheListHeight() {
        var height = NotesLayoutSettings.defaultListHeight
        let divider = PanelDividerView()
        divider.size = Binding(get: { height }, set: { height = $0 })
        divider.range = NotesLayoutSettings.listHeightRange
        divider.axis = .vertical

        XCTAssertEqual(divider.accessibilityRole(), .splitter)
        XCTAssertEqual(divider.accessibilityOrientation(), .horizontal)
        XCTAssertEqual(divider.accessibilityMinValue() as? Double, NotesLayoutSettings.listHeightMin)
        XCTAssertEqual(divider.accessibilityMaxValue() as? Double, NotesLayoutSettings.listHeightMax)
        XCTAssertTrue(divider.accessibilityPerformIncrement())
        XCTAssertEqual(height, NotesLayoutSettings.defaultListHeight + 10)
        XCTAssertTrue(divider.accessibilityPerformDecrement())
        XCTAssertEqual(height, NotesLayoutSettings.defaultListHeight)
        divider.setAccessibilityValue(10_000)
        XCTAssertEqual(height, NotesLayoutSettings.listHeightMax)
        divider.setAccessibilityValue(0)
        XCTAssertEqual(height, NotesLayoutSettings.listHeightMin)

        divider.axis = .horizontal   // switching back to side by side restores the vertical orientation
        XCTAssertEqual(divider.accessibilityOrientation(), .vertical)
    }
}
