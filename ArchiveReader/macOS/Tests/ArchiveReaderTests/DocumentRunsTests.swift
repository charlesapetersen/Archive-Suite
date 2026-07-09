import XCTest
@testable import ArchiveReader

final class DocumentRunsTests: XCTestCase {
    func testRunStartingAtStartIncludesContinuations() {
        let c: [String?] = ["Document Start", "Continuation", "Continuation", "Document Start", "Box"]
        XCTAssertEqual(DocumentRuns.run(startingAt: 0, classifications: c), 0...2)
        XCTAssertEqual(DocumentRuns.run(startingAt: 3, classifications: c), 3...3)  // lone start
    }

    func testRunContainingFromAnyPageInTheRun() {
        let c: [String?] = ["Document Start", "Continuation", "Continuation", "Document Start"]
        XCTAssertEqual(DocumentRuns.runContaining(0, classifications: c), 0...2)
        XCTAssertEqual(DocumentRuns.runContaining(1, classifications: c), 0...2)
        XCTAssertEqual(DocumentRuns.runContaining(2, classifications: c), 0...2)
        XCTAssertEqual(DocumentRuns.runContaining(3, classifications: c), 3...3)
    }

    func testUnknownClassificationDegradesToSingleItem() {
        let c: [String?] = [nil, nil, nil]
        XCTAssertEqual(DocumentRuns.run(startingAt: 0, classifications: c), 0...0)
        XCTAssertEqual(DocumentRuns.runContaining(1, classifications: c), 1...1)
    }

    func testMarkerBoundaryStopsRun() {
        let c: [String?] = ["Box", "Document Start", "Continuation"]
        XCTAssertEqual(DocumentRuns.run(startingAt: 1, classifications: c), 1...2)
        XCTAssertEqual(DocumentRuns.runContaining(2, classifications: c), 1...2)
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(DocumentRuns.run(startingAt: 5, classifications: ["Document Start"]))
    }
}
