import XCTest
@testable import ArchiveCore

/// Pure diff tests for `TagEditing.subjectDelta(from:to:)`.
final class SubjectTokenEditTests: XCTestCase {

    func testAddOne() {
        let d = TagEditing.subjectDelta(from: ["Economics"], to: ["Economics", "Taxes"])
        XCTAssertEqual(d.add, ["Taxes"])
        XCTAssertEqual(d.remove, [])
    }

    func testRemoveOne() {
        let d = TagEditing.subjectDelta(from: ["Economics", "Taxes"], to: ["Economics"])
        XCTAssertEqual(d.add, [])
        XCTAssertEqual(d.remove, ["Taxes"])
    }

    func testAddAndRemoveInOneDelta() {
        let d = TagEditing.subjectDelta(from: ["A", "B"], to: ["A", "C"])
        XCTAssertEqual(d.add, ["C"])
        XCTAssertEqual(d.remove, ["B"])
    }

    func testNoChangeIsEmpty() {
        XCTAssertTrue(TagEditing.subjectDelta(from: ["A", "B"], to: ["A", "B"]).isEmpty)
    }

    func testReorderOnlyIsNoOp() {
        XCTAssertTrue(TagEditing.subjectDelta(from: ["A", "B"], to: ["B", "A"]).isEmpty)
    }

    func testTrimsAddedToken() {
        XCTAssertEqual(TagEditing.subjectDelta(from: [], to: ["  Taxes "]).add, ["Taxes"])
    }

    func testDropsEmptyOrWhitespaceAdds() {
        XCTAssertTrue(TagEditing.subjectDelta(from: [], to: ["   ", ""]).isEmpty)
    }

    func testDeDupesAddedTokens() {
        XCTAssertEqual(TagEditing.subjectDelta(from: [], to: ["X", "X", " X "]).add, ["X"])
    }

    func testDoesNotReAddExistingSubject() {
        XCTAssertTrue(TagEditing.subjectDelta(from: ["X"], to: ["X", "X"]).isEmpty)
    }

    func testWhitespacePaddedSubjectIsNotChurned() {
        XCTAssertTrue(TagEditing.subjectDelta(from: [" Draft"], to: ["Draft"]).isEmpty)
    }

    func testWhitespacePaddedSubjectPreservedWhileAddingAnother() {
        let d = TagEditing.subjectDelta(from: [" Draft"], to: ["Draft", "Taxes"])
        XCTAssertEqual(d.add, ["Taxes"])
        XCTAssertEqual(d.remove, [], "the untouched whitespace-padded subject must not be removed")
    }
}
