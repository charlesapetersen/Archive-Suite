import ProcessorCore
import XCTest

/// The rotation agreement rule's verdicts (W46.rotation-default), moved out of the app's `RotationRuleTestDriver`
/// (section 1) by W49.proc-unit-test-target. The rest of that contract needs the app's gateway seam and stays there.
final class RotationAgreementTests: XCTestCase {
    private typealias V = RotationVerdict
    private func answers(_ value: Int?) -> @Sendable () async -> Int? { { value } }

    func testAgreementSettlesThePage() async {
        let v = await RotationAgreement.verdict(vision: 90, lcnet: 90, cloud: nil)
        XCTAssertEqual(v, V(correction: 90))
    }

    func testAgreementDoesNotCallTheCloud() async {
        let v = await RotationAgreement.verdict(vision: 0, lcnet: 0, cloud: { XCTFail("cloud called"); return 270 })
        XCTAssertEqual(v, V(correction: 0))
    }

    func testDisagreementWithNoCloudRouteIsLeftUnsure() async {
        let v = await RotationAgreement.verdict(vision: 90, lcnet: 270, cloud: nil)
        XCTAssertEqual(v, V(correction: 0, unsure: true))
    }

    func testVisionAbstainingWithNoCloudRouteIsLeftUnsure() async {
        let v = await RotationAgreement.verdict(vision: nil, lcnet: 180, cloud: nil)
        XCTAssertEqual(v, V(correction: 0, unsure: true))
    }

    func testLCNetAnsweringNothingNeverSettlesAPage() async {
        let v = await RotationAgreement.verdict(vision: 90, lcnet: nil, cloud: nil)
        XCTAssertEqual(v, V(correction: 0, unsure: true))
    }

    func testBuildWithoutLCNetRunsVisionAloneUnsure() async {
        let v = await RotationAgreement.verdict(vision: 90, lcnet: nil, cloud: nil, lcnetLoaded: false)
        XCTAssertEqual(v, V(correction: 90, unsure: true))
    }

    func testDisagreementTakesTheCloudsAnswer() async {
        let v = await RotationAgreement.verdict(vision: 90, lcnet: 270, cloud: answers(180))
        XCTAssertEqual(v, V(correction: 180))
    }

    func testFailedCloudCallFallsBackToVisionUnsure() async {
        let v = await RotationAgreement.verdict(vision: 90, lcnet: 270, cloud: answers(nil))
        XCTAssertEqual(v, V(correction: 90, unsure: true))
    }

    func testFailedCloudCallWithVisionAbstainingIsUnsure() async {
        let v = await RotationAgreement.verdict(vision: nil, lcnet: 270, cloud: answers(nil))
        XCTAssertEqual(v, V(correction: 0, unsure: true))
    }

    func testNoVerdictMarksAComparativeVoteFailure() async {
        // Only the llmSingle/llmMajority fallback sets it; the agreement rule never does.
        for (vision, lcnet) in [(90, 90), (90, 270)] as [(Int?, Int?)] {
            let v = await RotationAgreement.verdict(vision: vision, lcnet: lcnet, cloud: answers(nil))
            XCTAssertFalse(v.comparativeVoteFailed)
        }
    }
}
