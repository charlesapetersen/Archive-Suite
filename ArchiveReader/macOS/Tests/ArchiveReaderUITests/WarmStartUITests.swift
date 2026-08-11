import XCTest
import Darwin   // getpwuid / getuid — resolve the REAL home from the password DB

/// `W26.verify-fu2` — the warm-start UI, through the UI, for the first time.
///
/// `W26.idx` shipped warm start and `W26.verify` was supposed to check it in the VM; it could not,
/// because the XCUITest fixture lane has never HAD a warm start to look at (a fixture root answers NO
/// to `usesPersistedIndex`). The two DEBUG launch keys this suite uses close that gap:
/// `-ARUITestLibraryIndexPath` gives the lane a SCRATCH warm-start database, and
/// `-ARUITestScanHoldSeconds` holds the revalidation pass so `.revalidating` is a state the test enters
/// deliberately rather than a sub-100 ms transient it catches by luck. Measured while writing the unit
/// half: revalidating a small corpus settles inside 10 ms, so the luck version would have been the
/// `W21.vmgui-c` flake class again.
///
/// Unlike `FixtureUITestCase` this suite builds its OWN corpus, because two of the three checks need to
/// change the corpus between launches (an untagged tree; a file that goes away while the app is closed)
/// and the shared `AR-GUI-Fixture` is asserted on by every other UI test. Everything lives in a
/// throwaway directory this class creates and deletes: no real corpus, no shared fixture, and the app's
/// real `library-index-v1.sqlite3` is substituted away by the index key rather than merely unused.
///
/// VM lane only (`ops/gui/vm-gui-runner.sh reader xcuitest`) — never the owner's screen.
@MainActor
final class WarmStartUITests: XCTestCase {

    private var scratch: URL!
    private var corpus: URL!
    private var database: URL!
    private var app: XCUIApplication?

    /// The file test 3 deletes between launches. First alphabetically so it is the first row whatever
    /// the default sort does, though the test selects everything and does not depend on that.
    private let vanishing = "aaa-vanishes.pdf"
    private let tagged = ["aaa-vanishes.pdf", "bbb-stays.pdf", "ccc-stays.pdf"]
    private let untaggedExtra = "ddd-no-read-state.pdf"

    // `async` rather than the `…WithError` pair: XCTest's synchronous hooks are nonisolated, so on a
    // `@MainActor` class every touch of a stored property or of `XCUIApplication` there is a Swift 6
    // actor-isolation warning (nine of them, the same debt `FixtureUITestCase` carries). The async
    // overrides inherit the class's isolation, so the hooks are warning-free.
    override func setUp() async throws {
        continueAfterFailure = false
        scratch = try Self.makeScratchDirectory()
        corpus = scratch.appendingPathComponent("corpus", isDirectory: true)
        database = scratch.appendingPathComponent("warm-start.sqlite3")
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - (1) cached rows paint as revalidating, not settled

    func testWarmRowsPaintAsRevalidatingBeforeTheyPaintAsSettled() throws {
        try buildCorpus(withReadStates: true)
        try seedTheWarmStartCache()

        let warm = launch(hold: 20)
        let table = warm.tables["ar.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 30), "the main window should come up")
        // These rows can only have come from the cache: the filesystem pass is still held.
        waitForRows(warm, minimum: tagged.count, timeout: 30)

        XCTAssertTrue(warm.staticTexts["ar.status.scanning"].exists,
                      "cached rows must say they are still being revalidated, not pose as settled")
        XCTAssertFalse(warm.staticTexts["Finding tagged documents…"].exists,
                       "a revalidation must never blank the list behind the first-scan spinner")
        captureScreenshot("warmstart-revalidating")

        // And it is a *transient* claim, withdrawn by the pass it is waiting for.
        XCTAssertTrue(waitForDisappearance(warm.staticTexts["ar.status.scanning"], timeout: 60),
                      "the held pass must finish and the revalidating label go away")
        XCTAssertEqual(table.tableRows.count, tagged.count,
                       "the settled list is the same rows, now disk-verified")
        captureScreenshot("warmstart-settled")
    }

    // MARK: - (2) the settled sentence still quotes its examined-file denominator

    func testASettledPassOverAnUntaggedFolderQuotesTheFilesItExamined() throws {
        try buildCorpus(withReadStates: false)
        try seedTheWarmStartCache(expectingRows: 0)

        // Warm launch: the cache has every file but no *tracked* row, so this is the settled-after-
        // revalidation wording rather than a cold pass's.
        let warm = launch()
        let empty = warm.descendants(matching: .any)["ar.empty.nothingTagged"]
        XCTAssertTrue(empty.waitForExistence(timeout: 60),
                      "an untagged tree that was read completely may say so — and only then")
        captureScreenshot("warmstart-nothing-tagged")

        // `.accessibilityText`, never `.label`: a SwiftUI Text puts its string in the accessibility
        // VALUE and leaves the label empty (→ UITestText.swift). Reading `.label` here is what made
        // this check fail with an empty actual the first time it was ever able to run.
        let sentence = empty.accessibilityText
        XCTAssertTrue(sentence.contains("Scanned \(tagged.count + 1) files"),
                      "the denominator must be quoted, and be the real examined count: \(sentence)")
        XCTAssertTrue(sentence.contains("none carry a Read or Unread tag"),
                      "and the claim must stay scoped to read state: \(sentence)")
    }

    // MARK: - (3) a warm row is re-verified before it is written, not written blind

    func testAWarmRowWhoseFileVanishedIsRefusedRatherThanWrittenBlind() throws {
        try buildCorpus(withReadStates: true)
        try seedTheWarmStartCache()

        // The corpus changes while the app is closed — the case a cache cannot know about.
        try FileManager.default.removeItem(at: corpus.appendingPathComponent(vanishing))

        let warm = launch(hold: 60)
        let table = warm.tables["ar.table"]
        XCTAssertTrue(table.waitForExistence(timeout: 30))
        // All three rows, including the deleted file's: that is what makes this a blind-write hazard.
        waitForRows(warm, minimum: tagged.count, timeout: 30)
        XCTAssertTrue(warm.staticTexts["ar.status.scanning"].exists,
                      "the pass must still be held, or the stale row would already be gone")

        clickRow(table, 0)
        warm.typeKey("a", modifierFlags: .command)   // select every warm row
        toolbarButton(warm, "ar.toolbar.markRead").click()

        let status = warm.staticTexts["ar.status.message"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "the write must report what it did")
        captureScreenshot("warmstart-refused-blind-write")
        let message = status.accessibilityText   // the string is in the VALUE — see UITestText.swift
        XCTAssertTrue(message.contains("could not update"),
                      "the vanished cache row must be refused, not written: \(message)")
        XCTAssertTrue(message.contains("Marked \(tagged.count - 1)"),
                      "the rows that DO still exist are written normally: \(message)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: corpus.appendingPathComponent(vanishing).path),
                       "and nothing recreated the file the cache still named")
    }

    // MARK: - Launching

    private func launch(hold: TimeInterval? = nil) -> XCUIApplication {
        let app = XCUIApplication.archiveUITestApp()   // never a bare init — see UITestLaunch
        app.launchArguments += ["-ARUITestRootPath", corpus.path,
                               "-ARUITestLibraryIndexPath", database.path]
        if let hold { app.launchArguments += ["-ARUITestScanHoldSeconds", String(Int(hold))] }
        app.launch()
        app.activate()
        self.app = app
        return app
    }

    /// One cold launch whose only job is to leave a populated cache behind, then quit.
    ///
    /// The commit is asynchronous, so this waits for the database file to appear and stop growing
    /// rather than assuming a settled list means a written cache — a premature `terminate()` would
    /// leave the next launch cold and every warm assertion would fail for the wrong reason.
    private func seedTheWarmStartCache(expectingRows: Int? = nil) throws {
        let cold = launch()
        if !cold.tables["ar.table"].waitForExistence(timeout: 30) {
            reportWhatIsOnScreen(cold)
            XCTFail("the app never drew its file list over \(corpus.path)")
            return
        }
        let wanted = expectingRows ?? tagged.count
        if wanted > 0 { waitForRows(cold, minimum: wanted, timeout: 30) }
        XCTAssertTrue(waitForDisappearance(cold.staticTexts["ar.status.scanning"], timeout: 60),
                      "the seeding pass must settle before its cache is worth anything")
        try waitForTheCacheToBeWritten()
        cold.terminate()
        app = nil
    }

    /// Everything a stranger would need to tell "the app could not read my corpus" from "the app did not
    /// come up at all" — the two failures that look identical from a missing table.
    private func reportWhatIsOnScreen(_ app: XCUIApplication) {
        print("[warmstart] scratch=\(scratch.path)")
        print("[warmstart] corpus=\(corpus.path) exists=\(FileManager.default.fileExists(atPath: corpus.path))")
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: corpus.path)) ?? []
        print("[warmstart] corpus contents=\(listing.sorted())")
        print("[warmstart] database=\(database.path) exists=\(FileManager.default.fileExists(atPath: database.path))")
        print("[warmstart] app state=\(app.state.rawValue) windows=\(app.windows.count)")
        print("[warmstart] hierarchy:\n\(app.debugDescription)")
        captureScreenshot("warmstart-no-table")
    }

    private func waitForTheCacheToBeWritten(timeout: TimeInterval = 30) throws {
        var lastSize = -1
        var stableSince: Date?
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let size = (try? FileManager.default.attributesOfItem(atPath: database.path)[.size] as? Int) ?? nil
            if let size, size > 0 {
                if size == lastSize {
                    if let stableSince, Date().timeIntervalSince(stableSince) > 1.0 { return }
                    if stableSince == nil { stableSince = Date() }
                } else {
                    lastSize = size
                    stableSince = nil
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("the warm-start cache at \(database.path) was never written (last size \(lastSize))")
    }

    // MARK: - Corpus

    /// Build the scratch corpus. `withReadStates` false is check (2)'s tree: real files, real root
    /// marker, and not one `Read`/`Unread` tag between them — the only shape in which the app is
    /// allowed to say that nothing is tagged.
    private func buildCorpus(withReadStates: Bool) throws {
        try? FileManager.default.removeItem(at: corpus)
        try FileManager.default.createDirectory(at: corpus, withIntermediateDirectories: true)
        for (index, name) in (tagged + [untaggedExtra]).enumerated() {
            let url = corpus.appendingPathComponent(name)
            try Data("PDF fixture bytes \(index)".utf8).write(to: url)
            let tags: [String]
            if !withReadStates || name == untaggedExtra {
                tags = ["1979", "Budget Policy"]           // no read state: excluded from the library
            } else {
                tags = ["Unread", "1980", "Jerry Brown"]   // Unread, so Mark Read is a real change
            }
            try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        // A fixed GUID, exactly like `make-gui-fixture.sh`: the warm-start cache is keyed on the root
        // marker, so both launches must agree on it or the second one is cold by definition.
        let marker = #"{"guid":"b7e3c1a9-4d52-4f08-8a16-2c9f5e7d1043","name":"AR-WarmStart-Fixture","#
            + #""kind":"reader","createdAt":"2026-08-10T00:00:00Z"}"#
        try Data(marker.utf8).write(to: corpus.appendingPathComponent(".archive-suite-root.json"))
    }

    /// A directory this (sandboxed) test can write AND the app can read.
    ///
    /// The app's Debug-only temporary-exception entitlement covers `/Users/` and nothing else, so a
    /// `/private/var/folders` temporary directory would be invisible to it. The runner's own
    /// `temporaryDirectory` normally resolves inside its sandbox container — under `/Users/` — but that
    /// is a property of the container, not a guarantee, so it is CHECKED here. `AR_WARMSTART_ROOT` lets
    /// a harness supply a directory it prepared instead.
    private static func makeScratchDirectory() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["AR_WARMSTART_ROOT"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        candidates.append(FileManager.default.temporaryDirectory)
        let realHome: String
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            realHome = String(cString: dir)
        } else {
            realHome = FileManager.default.homeDirectoryForCurrentUser.path
        }
        candidates.append(URL(fileURLWithPath: "\(realHome)/Library/Application Support/ArchiveReader",
                              isDirectory: true))

        var tried: [String] = []
        for parent in candidates {
            guard parent.path.hasPrefix("/Users/") else {
                tried.append("\(parent.path) (not under /Users/, the app could not read it)")
                continue
            }
            let url = parent.appendingPathComponent("AR-WarmStart-\(UUID().uuidString)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                return url
            } catch {
                tried.append("\(url.path) (\(error.localizedDescription))")
            }
        }
        throw XCTSkip("no scratch directory that both the sandboxed runner can write and the app can "
                      + "read: tried \(tried.joined(separator: "; "))")
    }

    // MARK: - Element helpers
    //
    // Local rather than inherited: `FixtureUITestCase`'s `setUp` launches the shared fixture, which is
    // the one thing this suite must not do.

    private func waitForRows(_ app: XCUIApplication, minimum: Int, timeout: TimeInterval) {
        let table = app.tables["ar.table"]
        let deadline = Date().addingTimeInterval(timeout)
        while table.tableRows.count < minimum, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertGreaterThanOrEqual(table.tableRows.count, minimum,
                                    "expected at least \(minimum) rows within \(timeout)s")
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return !element.exists
    }

    @discardableResult
    private func clickRow(_ table: XCUIElement, _ index: Int, timeout: TimeInterval = 15) -> XCUIElement {
        let row = table.tableRows.element(boundBy: index)
        _ = row.waitForExistence(timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while !row.isHittable, Date() < deadline {
            app?.activate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if row.isHittable {
            row.click()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }
        return row
    }

    /// Same trap as `FixtureUITestCase.toolbarButton`: on macOS 26 a SwiftUI toolbar can surface one
    /// identifier on more than one accessibility element, so a bare lookup fails to click with
    /// "Multiple matching elements found".
    private func toolbarButton(_ app: XCUIApplication, _ id: String,
                               timeout: TimeInterval = 10) -> XCUIElement {
        let matches = app.windows["Archive Reader"].buttons.matching(identifier: id)
        _ = matches.firstMatch.waitForExistence(timeout: timeout)
        for i in 0..<matches.count where matches.element(boundBy: i).isHittable {
            return matches.element(boundBy: i)
        }
        return matches.firstMatch
    }
}
