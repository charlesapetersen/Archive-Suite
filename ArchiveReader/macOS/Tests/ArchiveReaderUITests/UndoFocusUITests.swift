import XCTest
import Darwin

/// W40.fix-reader-undo-focus (suspect S-001; owner session reader-1, rows 32 and 37), on the scratch fixture.
///
/// 1. With the caret in the file-name filter, ⌘Z undoes the typing and leaves the last tag change on disk.
/// 2. After a relaunch, with nothing clicked, ⌘Z undoes that tag change: the list has the keyboard at launch.
///
/// Tags are read from disk with fresh `getxattr` calls; teardown puts back every tag xattr it found.
final class UndoFocusUITests: FixtureUITestCase {
    private static let tagXattr = "com.apple.metadata:_kMDItemUserTags"
    private var root: URL { URL(fileURLWithPath: Self.fixturePath, isDirectory: true) }
    private var baseline: [String: Data?] = [:]

    override func setUp() async throws {
        try await super.setUp()
        try requireGeneratedScratchFixtureForTagWrites()
        baseline = tagSnapshot()
        continueAfterFailure = true   // report both halves; teardown restores the tags either way
    }

    override func tearDown() async throws {
        app?.terminate()
        guard !baseline.isEmpty else { return try await super.tearDown() }   // setup failed before any write
        for (path, bytes) in baseline where tagSnapshot()[path] != bytes {
            if let bytes {
                _ = bytes.withUnsafeBytes { setxattr(path, Self.tagXattr, $0.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
            } else {
                _ = removexattr(path, Self.tagXattr, XATTR_NOFOLLOW)
            }
        }
        XCTAssertEqual(tagSnapshot(), baseline, "teardown should leave the fixture's tags as it found them")
        try await super.tearDown()
    }

    func testCommandZBelongsToTheFocusedFieldAndWorksAtLaunch() throws {
        // A UITest launch gets a fresh undo ledger each time; this test shares one across its relaunch.
        app.terminate()
        app.launchArguments += ["-ARUITestLedgerID", UUID().uuidString]
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        waitForRows(minimum: 1, timeout: 15)
        clickRow(0)
        // One tag change: Mark Read, or Mark Unread if the row is already read.
        pressKey("r", modifiers: .command)
        var changed = waitForChange(from: baseline)
        if changed.isEmpty {
            pressKey("u", modifiers: .command)
            changed = waitForChange(from: baseline)
        }
        XCTAssertEqual(changed.count, 1, "precondition: one file's tags changed, got \(changed.keys.sorted())")
        let afterChange = tagSnapshot()

        // ⌘Z in the file-name filter: the typing goes, the tag change stays.
        let filter = app.textFields["ar.filter.name"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("zq")
        settle(0.5)
        XCTAssertEqual(filter.value as? String, "zq", "precondition: the typing landed in the filter")
        pressKey("z", modifiers: .command)
        settle(1.5)
        XCTAssertNotEqual(filter.value as? String, "zq", "⌘Z in the filter should undo the typing")
        XCTAssertEqual(tagSnapshot(), afterChange, "⌘Z in the filter must not undo the tag change (S-001)")
        // Leave the filter empty, whatever the undo left in it, so the list is whole after the relaunch.
        filter.click()
        pressKey("a", modifiers: .command)
        app.typeKey(.delete, modifierFlags: [])
        settle(0.5)

        // Relaunch and press ⌘Z before clicking anything: the undo history survives the relaunch (R-46).
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(table.waitForExistence(timeout: 10))
        waitForRows(minimum: 1, timeout: 15)
        settle(1)
        XCTAssertTrue(toolbarButton("ar.toolbar.undo").isEnabled, "precondition: the undo history survived the relaunch")
        XCTAssertEqual(table.value(forKey: "hasKeyboardFocus") as? Bool, true, "the list should have the keyboard at launch")
        pressKey("z", modifiers: .command)
        // The inverse write restores the tags, not necessarily the xattr's exact bytes, so compare the tags.
        let path = changed.keys.first ?? ""
        let before = Self.tags(baseline[path] ?? nil)
        XCTAssertTrue(waitFor { Self.tags(Self.xattr(path)) == before },
                      "⌘Z right after launch should undo the tag change without a click in the list first; "
                      + "tags now \(Self.tags(Self.xattr(path))), before \(before)")
    }

    // MARK: helpers

    /// Every fixture file's raw tag xattr, keyed by path; nil where a file has none.
    private func tagSnapshot() -> [String: Data?] {
        var out: [String: Data?] = [:]
        let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = walk?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "pdf" else { continue }
            out[url.path] = Self.xattr(url.path)
        }
        XCTAssertFalse(out.isEmpty, "precondition: the fixture has PDFs to watch")
        return out
    }

    private static func xattr(_ path: String) -> Data? {
        let size = getxattr(path, tagXattr, nil, 0, 0, XATTR_NOFOLLOW)
        guard size >= 0 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, tagXattr, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        return read == size ? data : nil
    }

    /// The files whose tags differ from `before`, waiting up to five seconds for a write to land.
    private func waitForChange(from before: [String: Data?]) -> [String: Data?] {
        var diff: [String: Data?] = [:]
        _ = waitFor(timeout: 5) {
            diff = self.tagSnapshot().filter { before[$0.key] != $0.value }
            return !diff.isEmpty
        }
        return diff
    }

    private func waitFor(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            settle(0.3)
        }
        return condition()
    }

    /// The Finder tags an xattr holds, sorted, with a missing colour suffix read as "\n0"; empty for none.
    private static func tags(_ data: Data?) -> [String] {
        guard let data, let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
        else { return [] }
        return list.map { $0.contains("\n") ? $0 : $0 + "\n0" }.sorted()
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
}
