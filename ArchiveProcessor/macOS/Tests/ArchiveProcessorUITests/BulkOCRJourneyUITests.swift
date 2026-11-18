import XCTest

// W40.d1 — bulk OCR on a ground-truth collection. The real Process Files pipeline (OCR, segmentation by the
// shipped default approach, tagging, the two-page PDFs and their Finder tags) runs on a guest copy of a
// rehearsal box through `ProcessFilesTestDriver`, the app's own headless driver, launched here so it runs in
// the VM's window server and never on the host's screen.
//
// It runs only in `PROCESSOR_JOURNEY=bulkocr ops/gui/vm-gui-runner.sh processor xcuitest` (driven by
// `ArchiveProcessor/scripts/journey-bulk-ocr.sh`), which copies the box into TEST_RUNNER_W40D1_DIR/in, writes
// the key file there for a paid route, and afterwards brings TEST_RUNNER_W40D1_DIR/out back for the host's
// checker (`scripts/journey_bulk_ocr_check.py`). Every other run skips it. The verdict on the output is the
// checker's; this test asserts only that the driver finished and said so.
@MainActor
final class BulkOCRJourneyUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["W40D1_DIR"]?.isEmpty == false else {
            throw XCTSkip("W40.d1 journey: runs only under PROCESSOR_JOURNEY=bulkocr")
        }
        app = .archiveProcessorUITestApp()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testBulkOCRThroughProcessFiles() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = URL(fileURLWithPath: env["W40D1_DIR"]!, isDirectory: true)
        // The runner is sandboxed and cannot read the guest folder; the app is not, so it writes its done
        // marker where this runner can read it.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("w40d1-DONE-\(UUID().uuidString).txt")
        var launch: [String: String] = [
            "ARCHIVEPROC_HEADLESS": "1",
            "PROCESSFILES_TESTMODE": "1",
            "PROCESSFILES_TESTIN": dir.appendingPathComponent("in").path,
            "PROCESSFILES_TESTOUT": dir.appendingPathComponent("out").path,
            "PROCESSFILES_TESTDONE": marker.path,
        ]
        // Passed through as the runner named them (TEST_RUNNER_W40D1_<NAME> → PROCESSFILES_<NAME>).
        for name in ["PROVIDER", "MODEL", "TAGGING", "MAXIMAGES", "GATEWAY_URL", "GATEWAY_MODEL",
                     "GATEWAY_IN_PER_1M", "GATEWAY_OUT_PER_1M", "GATEWAY_UPSTREAM", "CAP_USD", "METER", "BATCH",
                     "BATCH_CANCEL"] {
            if let v = env["W40D1_\(name)"], !v.isEmpty { launch["PROCESSFILES_\(name)"] = v }
        }
        if env["W40D1_KEYFILE"] == "1" {
            launch["PROCESSFILES_TESTKEYFILE"] = dir.appendingPathComponent("key").path
        }
        app.launchEnvironment.merge(launch) { _, new in new }
        app.launch()

        let limit = Double(env["W40D1_TIMEOUT_S"] ?? "") ?? 5400
        let start = Date()
        var lastNote = start
        while !FileManager.default.fileExists(atPath: marker.path) && Date().timeIntervalSince(start) < limit {
            Thread.sleep(forTimeInterval: 5)
            // A line a minute, so the VM lane's stall guard sees a live run.
            if Date().timeIntervalSince(lastNote) >= 60 {
                lastNote = Date()
                print("[w40d1] waiting for the driver, \(Int(lastNote.timeIntervalSince(start))) s")
            }
        }
        let text = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        print("[w40d1] driver: \(text.isEmpty ? "(no marker)" : text) after \(Int(Date().timeIntervalSince(start))) s")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "the driver must finish within \(Int(limit)) s")
        XCTAssertFalse(text.hasPrefix("ERROR"), "the driver refused or failed: \(text)")
    }
}
