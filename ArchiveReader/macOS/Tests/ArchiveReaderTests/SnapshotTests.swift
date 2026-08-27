// SnapshotTests.swift — reference-image regression testing (pointfreeco/swift-snapshot-testing).
//
// Complements RenderProbe's property guards ("did it draw at all?") with exact-ish reference
// diffs ("does it still look the way it did?"). Runs headless in the unit bundle — no app
// launch, no XCUITest, no TCC prompt.
//
// References live in `__Snapshots__/` next to this file and are committed. The Tart VM is the reference
// renderer: to regenerate after an intended visual change, set `recordMode` to `.all` once and run the
// Reader VM lane. The test writes its sandbox-local recording to tmp and the unsandboxed runner copies it
// back to `__Snapshots__/`; set it back to `.missing` and re-run to compare. `perceptualPrecision` absorbs
// sub-perceptual antialiasing drift from OS updates.
//
// A failing diff writes both the reference and the failing render to disk; open them (or ask a
// session to `Read` them) to adjudicate whether a change is a real regression.

import XCTest
import SwiftUI
import SnapshotTesting

final class SnapshotTests: XCTestCase {

    /// `.all` regenerates the guest reference through the VM runner (flip here, run once, flip back);
    /// `.missing` compares against the committed guest-rendered reference.
    private let recordMode: SnapshotTestingConfiguration.Record = .missing
    private let referenceFileName = "testDeterministicViewMatchesReference.1.png"

    /// True inside the Tart GUI VM (an Apple-Virtualization guest reports `hw.model` as `VirtualMac*`).
    ///
    /// Snapshot pixels are renderer-specific: the Tart guest is the one reference machine, so this test
    /// deliberately skips on the host. The app-hosted test runner is sandboxed and cannot update the shared
    /// repo; its intentional `.all` recording therefore goes to its own tmp directory, emits a `[shot]`
    /// path, and `vm-gui-runner.sh` copies that one named artifact back to the committed reference.
    private var isVirtualMachine: Bool {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return false }
        var chars = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &chars, &size, nil, 0) == 0 else { return false }
        return String(decoding: chars.prefix(while: { $0 != 0 }).map(UInt8.init(bitPattern:)),
                      as: UTF8.self).hasPrefix("VirtualMac")
    }

    @MainActor
    func testDeterministicViewMatchesReference() throws {
        try XCTSkipUnless(
            isVirtualMachine,
            """
            Skipped on the host: SnapshotTests uses the Tart VM as its reference renderer because host and \
            guest rasterise this view differently. Run `ops/gui/vm-gui-runner.sh reader xcuitest`.
            """
        )
        // Pure geometry + colour (no text) → stable across runs on this machine.
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.28, blue: 0.6),
                                    Color(red: 0.05, green: 0.11, blue: 0.3)],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.9))
                .frame(width: 120, height: 60)
            Circle().stroke(.white, lineWidth: 4).frame(width: 40, height: 40)
        }
        .frame(width: 300, height: 180)

        let host = NSHostingController(rootView: view)
        host.view.frame = CGRect(x: 0, y: 0, width: 300, height: 180)

        let strategy = Snapshotting<NSViewController, NSImage>.image(
            precision: 0.99, perceptualPrecision: 0.98)
        if recordMode == .all {
            let fileManager = FileManager.default
            let recordingDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("ArchiveReaderSnapshotTests-\(UUID().uuidString)", isDirectory: true)
            let recordedReference = recordingDirectory.appendingPathComponent(referenceFileName)
            let message = verifySnapshot(
                of: host,
                as: strategy,
                named: "1",
                record: .all,
                snapshotDirectory: recordingDirectory.path
            )
            XCTAssertTrue(message?.contains("Record mode is on. Automatically recorded snapshot") == true,
                          "the VM recording must be explicitly confirmed by SnapshotTesting")
            XCTAssertTrue(fileManager.isReadableFile(atPath: recordedReference.path),
                          "the VM reference must be written to the test host's own temporary directory")
            XCTAssertGreaterThan(try Data(contentsOf: recordedReference).count, 0,
                                 "the VM reference must contain rendered pixels before it is promoted")
            print("[shot] reader-snapshot-reference: wrote \(recordedReference.path)")
        } else {
            assertSnapshot(of: host, as: strategy, named: "1", record: recordMode)
        }
    }
}
