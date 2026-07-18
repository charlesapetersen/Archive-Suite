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

    @MainActor
    func testDeterministicViewMatchesReference() {
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
