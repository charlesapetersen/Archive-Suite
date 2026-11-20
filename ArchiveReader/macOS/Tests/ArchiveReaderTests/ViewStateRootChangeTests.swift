import XCTest
@testable import ArchiveReader

/// Suspect S-004 (`W49.reader-s004-reproduce`): a folder scope saved in `ar.viewState` under one root, restored
/// in `NavigationModel.init` on another. The suspicion was that `restoreViewState` could run before
/// `rootStore.discoveredPathPrefix` is known, so `sanitizedPathPrefix` would pass the old prefix through and the
/// new root's list would read as empty. These run the real bookmark path, not the fixture pin: the pin turns
/// view-state restore off altogether, so a fixture test could not see the defect either way.
@MainActor
final class ViewStateRootChangeTests: XCTestCase {

    private func scratchRoot(_ name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ViewStateRootChangeTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent("Box 1/\(name).pdf")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("BYTES-\(UUID().uuidString)".utf8).write(to: file)
        try (URL(fileURLWithPath: file.path) as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Grant `root` in `defaults` the way the open panel does, so the next model resolves it from the bookmark.
    private func grant(_ root: URL, in defaults: UserDefaults) {
        let store = RootFolderStore(defaults: defaults)
        XCTAssertNil(store.setRoot(root), "precondition: the scratch root bookmarks")
    }

    private func waitUntilSettled(_ model: NavigationModel, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(30)
        while !model.library.phase.isSettled, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(model.library.phase.isSettled, "the scratch root's scan settles", file: file, line: line)
        model.recompute()
    }

    /// Opens a model on root A, scopes it to A's "Box 1" and lets it save its view state.
    private func saveScopeUnderRootA(_ a: URL, in defaults: UserDefaults) throws -> String {
        grant(a, in: defaults)
        let model = NavigationModel(defaults: defaults)
        waitUntilSettled(model)
        model.filter.read = .all
        let box = try XCTUnwrap(model.rootStore.discoveredPathPrefix) + "/Box 1"
        model.setFolderScope(box)
        model.recompute()   // persists `ar.viewState`
        XCTAssertEqual(model.displayed.count, 1, "precondition: A's box lists A's file")
        XCTAssertNotNil(defaults.data(forKey: "ar.viewState"), "precondition: the scope was saved")
        return box
    }

    func testAFolderScopeSavedUnderAnotherRootIsDroppedAtLaunch() throws {
        let defaults = fixtureDefaults()
        let a = try scratchRoot("a")
        let b = try scratchRoot("b")
        _ = try saveScopeUnderRootA(a, in: defaults)

        grant(b, in: defaults)
        let model = NavigationModel(defaults: defaults)
        XCTAssertNotNil(model.rootStore.discoveredPathPrefix,
                        "the root store resolves its bookmark in its own init, before the view state is restored")
        XCTAssertNil(model.filter.pathPrefix, "A's folder cannot scope B's list")
        XCTAssertEqual(model.filter.read, .all, "the rest of the saved view state is still restored")
        waitUntilSettled(model)
        XCTAssertEqual(model.displayed.map { $0.url.lastPathComponent }, ["b.pdf"], "root B lists its file")
    }

    /// The control: the same saved scope under its own root survives, so the test above is not passing because
    /// restore drops every prefix.
    func testAFolderScopeSavedUnderTheSameRootIsKeptAtLaunch() throws {
        let defaults = fixtureDefaults()
        let a = try scratchRoot("a")
        let box = try saveScopeUnderRootA(a, in: defaults)

        let model = NavigationModel(defaults: defaults)
        XCTAssertEqual(model.filter.pathPrefix, box)
        waitUntilSettled(model)
        XCTAssertEqual(model.displayed.map { $0.url.lastPathComponent }, ["a.pdf"])
    }
}
