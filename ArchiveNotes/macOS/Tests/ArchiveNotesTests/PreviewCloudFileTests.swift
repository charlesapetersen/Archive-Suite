import Foundation
import PDFKit
import XCTest
@testable import ArchiveNotes

/// W49.notes-s007-fix: the source-block preview opened its PDF bare, which downloaded a whole cloud
/// placeholder. A unit test cannot make a dataless file (and an engine session runs with materialisation off
/// process-wide), so these test the decision with an injected stat; the download itself was re-checked by
/// hand with the S-007 evidence probe.
final class PreviewCloudFileTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/nonexistent/source.pdf")

    private func onePagePDF() -> PDFDocument {
        let doc = PDFDocument()
        doc.insert(PDFPage(), at: 0)
        return doc
    }

    func testAPlaceholderIsReportedAndNeverOpened() {
        var opened = false
        let result = PreviewCloudFile.opening(url, isDataless: { _ in true }, open: { _ in
            opened = true
            return self.onePagePDF()
        })
        guard case .inCloud = result else { return XCTFail("a dataless file must be reported as in the cloud") }
        XCTAssertFalse(opened, "PDFKit must not be handed a placeholder at all")
    }

    func testALocalFileOpensWithMaterialisationOffForTheOpen() {
        var policyDuringOpen: Int32 = -99
        let result = PreviewCloudFile.opening(url, isDataless: { _ in false }, open: { _ in
            policyDuringOpen = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            return self.onePagePDF()
        })
        guard case .show(let doc) = result else { return XCTFail("a local PDF must open") }
        XCTAssertEqual(doc.pageCount, 1)
        XCTAssertEqual(policyDuringOpen, IOPOL_MATERIALIZE_DATALESS_FILES_OFF,
                       "the open must run with this thread's materialisation turned off")
    }

    func testALocalFileThatWillNotOpenIsUnreadable() {
        let result = PreviewCloudFile.opening(url, isDataless: { _ in false }, open: { _ in nil })
        guard case .unreadable = result else { return XCTFail("a local file PDFKit refuses is unreadable") }
    }

    func testAFileEvictedBeforeTheOpenIsReportedAsInTheCloud() {
        var stats = 0
        let result = PreviewCloudFile.opening(url, isDataless: { _ in
            stats += 1
            return stats > 1
        }, open: { _ in nil })
        guard case .inCloud = result else {
            return XCTFail("a nil open on a file that is dataless by then is in the cloud, not unreadable")
        }
    }

    func testAnOrdinaryFileIsNotDatalessAndDownloadRestoresThePolicy() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("s007-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertFalse(PreviewCloudFile.isDataless(file))
        XCTAssertFalse(PreviewCloudFile.isDataless(url), "a failed stat is not a placeholder")

        let before = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
        XCTAssertTrue(PreviewCloudFile.download(file), "a local file is already downloaded")
        XCTAssertFalse(PreviewCloudFile.download(url), "a missing file cannot be downloaded")
        XCTAssertEqual(getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD), before,
                       "download must hand the thread back its previous policy")
    }
}
