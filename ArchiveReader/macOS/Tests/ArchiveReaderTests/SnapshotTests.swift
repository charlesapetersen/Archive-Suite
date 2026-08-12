// SnapshotTests.swift — reference-image regression testing (pointfreeco/swift-snapshot-testing).
//
// Complements RenderProbe's property guards ("did it draw at all?") with exact-ish reference
// diffs ("does it still look the way it did?"). Runs headless in the unit bundle — no app
// launch, no XCUITest, no TCC prompt.
//
// References live in `__Snapshots__/` next to this file and are committed. To regenerate after
// an intended visual change, set `record = true` once, run, then set it back and commit the new
// PNG. `perceptualPrecision` absorbs sub-perceptual antialiasing drift from OS updates.
//
// A failing diff writes both the reference and the failing render to disk; open them (or ask a
// session to `Read` them) to adjudicate whether a change is a real regression.

import XCTest
import SwiftUI
import SnapshotTesting

final class SnapshotTests: XCTestCase {

    /// `.all` regenerates the reference (flip here, run once, flip back, commit the new PNG);
    /// `.missing` records only when no reference exists yet, otherwise compares.
    private let recordMode: SnapshotTestingConfiguration.Record = .missing

    /// True inside the Tart GUI VM (an Apple-Virtualization guest reports `hw.model` as `VirtualMac*`).
    ///
    /// **Why this test skips in the VM, when everything else runs there.** A pixel reference is only
    /// meaningful against one renderer, and the same view rasterises differently on the host and in the
    /// guest — so one of the two must be the reference machine and the other must not compare. That
    /// choice is forced, not preferred: **the reference cannot be recorded in the VM.** The repo is a
    /// read-only shared mount there and the test host is sandboxed, so recording fails with *"You don't
    /// have permission to save the file … in the folder SnapshotTests"* (measured 2026-08-12). Since the
    /// reference can only ever be produced on the host, the host is where it must be compared.
    ///
    /// The visual coverage automation *does* get is `RenderProbe` / `DocumentRenderGuardTests`, which
    /// assert on rendered pixels without needing a committed reference and so run fine in the guest.
    ///
    /// Making this run in the VM means teaching the test to write its recording to the guest's own tmp
    /// and having `vm-gui-runner.sh` copy it back — the same trick `collect_shots` already does for
    /// screenshots. That is unbuilt; see `SUITE_TODO.md`.
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
        try XCTSkipIf(
            isVirtualMachine,
            """
            Skipped in the GUI VM: the committed reference is host-rendered and the guest rasterises \
            differently, so comparing here reports a renderer difference rather than a change to the \
            view. It cannot be re-recorded here either — the repo is a read-only shared mount and this \
            test host is sandboxed. Run the Reader's tests on the host for this one assertion.
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

        assertSnapshot(
            of: host,
            as: .image(precision: 0.99, perceptualPrecision: 0.98),
            record: recordMode
        )
    }
}
