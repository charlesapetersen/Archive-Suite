import XCTest
import SwiftUI
@testable import ArchiveReader

/// W40.fix-reader-tagcloud-threshold: the tag cloud's minimum-count control.
final class TagCloudThresholdTests: XCTestCase {
    private let cloud: [(tag: String, count: Int)] = [("Budget", 1), ("Economics", 3), ("Jerry Brown", 7)]

    private func tags(_ minimum: Int, keeping active: Set<String> = []) -> [String] {
        NavigationModel.tagCloud(cloud, minimumCount: minimum, keeping: active).map(\.tag)
    }

    func testOneOrLessShowsEveryTag() {
        XCTAssertEqual(tags(1), ["Budget", "Economics", "Jerry Brown"])
        XCTAssertEqual(tags(0), ["Budget", "Economics", "Jerry Brown"])
    }

    func testHidesTagsOnFewerFilesThanTheMinimumAndKeepsTheOrder() {
        XCTAssertEqual(tags(3), ["Economics", "Jerry Brown"], "a tag on exactly N files stays")
        XCTAssertEqual(tags(4), ["Jerry Brown"])
        XCTAssertEqual(tags(8), [])
    }

    func testATagInTheFilterStaysSoItCanBeClickedOff() {
        XCTAssertEqual(tags(4, keeping: ["Budget"]), ["Budget", "Jerry Brown"])
    }

    func testATagInTheFilterInAnotherCaseStays() {
        XCTAssertEqual(tags(4, keeping: ["budget"]), ["Budget", "Jerry Brown"], "case variants are one tag")
    }

    @MainActor
    func testThresholdControlRendersAtMinimumPanelWidth() throws {
        for scheme in [ColorScheme.light, .dark] {
            for minimum in [1, 7, 999] {
                let control = TagCloudThresholdControl(minimumCount: .constant(minimum), maximumCount: 12)
                    .padding(10).environment(\.colorScheme, scheme)
                let view = NSHostingView(rootView: control)
                let png = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: view, size: CGSize(width: 160, height: 70)))
                writeRenderArtifact(png, named: "tagcloud-threshold-\(minimum)-\(scheme).png")
                assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "tag cloud threshold")
            }
        }
    }

    func testTheMinimumIsResetOnAFixtureUITestLaunch() {
        XCTAssertTrue(ReaderUITestDefaults.paneKeys.contains("ar.tagCloudMinCount"))
    }
}
