import XCTest
import Foundation
@testable import ArchiveReader

/// The one way a test in this bundle is allowed to pin the app to a fixture root.
///
/// **Why this exists (`W26.fixturehang`).** `ARUITestRootPath` is the DEBUG key that pins the Reader to a
/// scratch corpus. Eleven writes across six files set it in `UserDefaults.standard` — the shared
/// `com.archivereader.app` domain, because the unit bundle is app-hosted and *is* the Reader — and undid
/// it in a `defer` or an `addTeardownBlock`. A killed test host runs neither. So a bundle that timed out,
/// or that the daemon's watchdog tree-killed, left the pin in the owner's real defaults, and every later
/// launch — the owner's actual app included — started in fixture mode pinned to an `mktemp` directory
/// that no longer existed. Observed twice on 2026-08-07 (`SymlinkedRootTests-9ED68E63…`, then
/// `-2F56A414…`), i.e. it re-leaked routinely rather than once. While the fixture lane still started
/// FSEvents inline it also HUNG the whole bundle, and with it the daemon's health gate.
///
/// The fix is not a better teardown — no teardown runs on `SIGKILL`. It is to write the pin somewhere
/// production never reads, so that a leak is inert by construction rather than by cleanup.
///
/// The suite is named after the test, and cleared **on the way in as well as out**: a deterministic name
/// means a killed host leaves at most one stale plist instead of one per run, and clearing on entry means
/// that stale plist cannot bleed into the next run of the same test.
extension XCTestCase {

    /// A throwaway defaults domain for this test, optionally pinning the fixture root.
    ///
    /// Pass the result to `NavigationModel(defaults:)`, `ArchiveLibrary(defaults:)` or
    /// `RootFolderStore(defaults:)`. Nothing any of them writes — the pin, `archiveRootBookmark`,
    /// `ar.viewState`, `lastSelectionFileURLs`, `ar.excludedFolders` — can then reach the owner's app.
    @MainActor
    func fixtureDefaults(pinnedTo root: URL? = nil,
                         _ testName: String = #function,
                         file: StaticString = #filePath, line: UInt = #line) -> UserDefaults {
        let suiteName = "\(type(of: self)).\(testName)"
        // A suite named after the app's bundle identifier IS `.standard`, which would silently
        // reintroduce the whole defect behind an API that promises the opposite.
        XCTAssertNotEqual(suiteName, Bundle.main.bundleIdentifier,
                          "a fixture suite must never be the app's own domain", file: file, line: line)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("could not open the throwaway suite \(suiteName)", file: file, line: line)
            // Never `.standard`: returning it would put the writes this exists to contain straight
            // back into the owner's domain. An empty volatile domain fails the test loudly instead.
            return UserDefaults(suiteName: "\(suiteName).fallback-\(UUID().uuidString)")!
        }
        if let root { suite.set(root.path, forKey: "ARUITestRootPath") }
        return suite
    }

    /// A `NavigationModel` pinned to a scratch root, reading and writing nothing outside its own domain.
    ///
    /// Replaces the `navModel(root:)` helper that three test classes had each written for themselves,
    /// every copy against `.standard`.
    @MainActor
    func fixtureNavigationModel(pinnedTo root: URL,
                                _ testName: String = #function,
                                file: StaticString = #filePath, line: UInt = #line) -> NavigationModel {
        NavigationModel(defaults: fixtureDefaults(pinnedTo: root, testName, file: file, line: line))
    }
}
