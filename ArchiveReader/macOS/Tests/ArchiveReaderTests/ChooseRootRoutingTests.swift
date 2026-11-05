import XCTest
@testable import ArchiveReader

/// `W40.fix-reader-choose-folder-shortcut`: File ▸ Choose Archive Folder… (⇧⌘O) with no navigation window in
/// front brings that window forward and runs the panel on its model, once, whether the model is already
/// attached (the window was only behind a document window) or attaches later (the window had been closed).
@MainActor
final class ChooseRootRoutingTests: XCTestCase {

    private func scratchRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ChooseRootRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func drainMainQueue() {
        for _ in 0..<5 { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testAttachedModelRunsThePanelOnceAfterTheWindowComesForward() throws {
        let model = fixtureNavigationModel(pinnedTo: try scratchRoot())
        let router = DeepLinkRouter()
        router.nav = model
        var ran: [ObjectIdentifier] = []
        router.chooseRootAction = { ran.append(ObjectIdentifier($0)) }
        var broughtForward = 0
        router.requestChooseRoot { broughtForward += 1 }
        XCTAssertEqual(broughtForward, 1, "the navigation window is brought forward")
        XCTAssertTrue(ran.isEmpty, "the panel waits a turn, so the window is in front before it runs")
        drainMainQueue()
        XCTAssertEqual(ran, [ObjectIdentifier(model)])
        XCTAssertFalse(router.chooseRootPending)
    }

    func testModelThatAttachesLaterRunsThePanelOnce() throws {
        let router = DeepLinkRouter()
        var ran: [ObjectIdentifier] = []
        router.chooseRootAction = { ran.append(ObjectIdentifier($0)) }
        router.requestChooseRoot {}
        drainMainQueue()
        XCTAssertTrue(ran.isEmpty, "nothing to run on until the navigation window's model attaches")
        XCTAssertTrue(router.chooseRootPending)

        let model = fixtureNavigationModel(pinnedTo: try scratchRoot())
        router.nav = model   // the reappearing window's `onAppear`
        drainMainQueue()
        XCTAssertEqual(ran, [ObjectIdentifier(model)])
        XCTAssertFalse(router.chooseRootPending)

        router.nav = model   // a later `onAppear` must not bring the panel up again
        drainMainQueue()
        XCTAssertEqual(ran.count, 1)
    }

    func testOrdinaryAttachDoesNotRunThePanel() throws {
        let router = DeepLinkRouter()
        var ran = 0
        router.chooseRootAction = { _ in ran += 1 }
        router.nav = fixtureNavigationModel(pinnedTo: try scratchRoot())
        drainMainQueue()
        XCTAssertEqual(ran, 0)
    }
}
