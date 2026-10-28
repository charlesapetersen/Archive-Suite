import AppKit
import SwiftUI
import XCTest
@testable import ArchiveNotes

@MainActor
final class PanelDividerAccessibilityTests: XCTestCase {
    func testVoiceOverResizesTheSameWidthWithinTheDragLimits() {
        var width = 210.0
        let divider = PanelDividerView()
        divider.width = Binding(get: { width }, set: { width = $0 })
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
}
