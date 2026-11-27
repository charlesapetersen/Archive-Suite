import ProcessorCore
import XCTest

/// W49.proc-ocr-scale-by-pixels: the upload scale follows the encoded JPEG, not the input file's bytes.
final class OCRUploadScaleTests: XCTestCase {
    private func scale(source: Int, encoded: Int, bytes: Int, target: Double) -> Double {
        OCRUploadScale.dimensionScale(sourceLongEdge: source, encodedLongEdge: encoded, encodedBytes: bytes,
                                      targetBytes: target)
    }

    func testAJPEGWithinTheTargetIsSentAtFullScale() {
        // The owner's case: a 2000×1500 scan whose TIFF is 12.3 MB encodes to well under 3 MB, so it is not shrunk.
        XCTAssertEqual(scale(source: 2000, encoded: 2000, bytes: 1_400_000, target: 3_000_000), 1.0)
        XCTAssertEqual(scale(source: 2000, encoded: 2000, bytes: 3_000_000, target: 3_000_000), 1.0)
    }

    func testAJPEGOverTheTargetShrinksByTheSquareRootOfTheBytes() {
        let s = scale(source: 2000, encoded: 2000, bytes: 4_000_000, target: 1_000_000)
        XCTAssertEqual(s, 0.5, accuracy: 0.0005)
    }

    func testTheScaleIsRelativeToTheSourceAfterTheCap() {
        // A 4000 px photo capped to 2048 px whose JPEG is 4× the target goes up at a 1024 px long edge.
        let s = scale(source: 4000, encoded: 2048, bytes: 4_000_000, target: 1_000_000)
        XCTAssertEqual(s * 4000, 1024, accuracy: 0.5)
    }

    func testUnknownOrEmptyInputsLeaveTheScaleAlone() {
        XCTAssertEqual(scale(source: 0, encoded: 2048, bytes: 4_000_000, target: 1), 1.0)
        XCTAssertEqual(scale(source: 2000, encoded: 2000, bytes: 0, target: 1), 1.0)
    }

    func testTheScaleNeverReachesZero() {
        let s = scale(source: 2000, encoded: 2000, bytes: 4_000_000, target: 0)
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThanOrEqual(s, 1)
    }
}
