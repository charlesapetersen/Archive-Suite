import XCTest
@testable import ArchiveReader

/// R-4: `NavigationModel.sanitizedPathPrefix` guards a restored/saved filter whose folder scope may
/// predate a root change. It must drop a prefix outside the current root but keep a valid subtree, so
/// `applySaved`/`restoreViewState` never restore a scope that makes recompute reject every file.
final class NavigationModelTests: XCTestCase {

    func testSanitizedPathPrefixKeepsValidSubtree() {
        let root = "/Users/x/Archive"
        // The root itself and any subtree under it are valid.
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix(root, against: root), root)
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/Users/x/Archive/Box1", against: root),
                       "/Users/x/Archive/Box1")
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/Users/x/Archive/Box1/Folder2", against: root),
                       "/Users/x/Archive/Box1/Folder2")
        // A trailing slash on the root is tolerated.
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/Users/x/Archive/Box1", against: root + "/"),
                       "/Users/x/Archive/Box1")
    }

    func testSanitizedPathPrefixDropsOutOfRootPrefix() {
        let root = "/Users/x/Archive"
        // A scope under a different root is dropped.
        XCTAssertNil(NavigationModel.sanitizedPathPrefix("/Users/x/OtherRoot/Box1", against: root))
        // A sibling whose path merely shares a NAME prefix (ArchiveBox vs Archive) must NOT survive —
        // the component-boundary test is why we don't use a plain hasPrefix.
        XCTAssertNil(NavigationModel.sanitizedPathPrefix("/Users/x/ArchiveBox", against: root))
        XCTAssertNil(NavigationModel.sanitizedPathPrefix("/Users/x/ArchiveBox/Sub", against: root))
    }

    func testSanitizedPathPrefixPassesThroughWhenNothingToValidate() {
        // No prefix → nil; no root → prefix unchanged (nothing to validate against).
        XCTAssertNil(NavigationModel.sanitizedPathPrefix(nil, against: "/Users/x/Archive"))
        XCTAssertEqual(NavigationModel.sanitizedPathPrefix("/anything", against: nil), "/anything")
    }
}

/// `W26.fixturehang` half (a), remainder: a `NavigationModel` on an injected domain must touch NO key in
/// the owner's.
///
/// This is the assertion the item is actually about. The pin, `ar.viewState`, `lastSelectionFileURLs`,
/// `archiveRootBookmark` and `ar.excludedFolders` all lived in the shared `com.archivereader.app` domain
/// — the unit bundle is app-hosted, so it *is* the Reader — and were undone in `defer`/`addTeardownBlock`.
/// A killed host runs neither, which is how a fixture pin outlived its run and put the owner's real app
/// into fixture mode against a deleted `mktemp` directory (observed twice on 2026-08-07).
///
/// Non-vacuity: reverting any single hunk of the source change turns one of these RED. Put
/// `persistSelection` back on `.standard` → the first case sees the key change. Put `persistViewState` or
/// `isUITestMode` back → the second (that pairing is the trap: with `isUITestMode` reading `.standard`
/// and the tests no longer writing the pin there, the guard reads nil, every test stops counting as a UI
/// test, and the view-state write it was suppressing lands on the owner's saved filter and sort).
@MainActor
final class NavigationModelDefaultsIsolationTests: XCTestCase {

    /// Every key a `NavigationModel` and the stores it owns can write.
    private static let ownedKeys = ["ARUITestRootPath", "ar.viewState", "lastSelectionFileURLs",
                                   "archiveRootBookmark", "ar.excludedFolders"]

    /// `Any?` out of the real domain, compared as its property-list encoding so `Data`, `[String]` and
    /// absence all compare properly without knowing each key's type.
    private func realDomainSnapshot() -> [String: Data] {
        var snapshot: [String: Data] = [:]
        for key in Self.ownedKeys {
            if let value = UserDefaults.standard.object(forKey: key),
               let encoded = try? PropertyListSerialization.data(fromPropertyList: [value],
                                                                 format: .binary, options: 0) {
                snapshot[key] = encoded
            }
        }
        return snapshot
    }

    private func scratchRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("NavDefaultsIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("doc.pdf")
        try Data("scratch PDF".utf8).write(to: pdf)
        try (pdf as NSURL).setResourceValue(["Unread"], forKey: .tagNamesKey)
        return root
    }

    /// A PINNED model: the resumed selection is written, and it is written to the injected suite.
    func testAPinnedModelPersistsItsSelectionOnlyInTheInjectedDomain() throws {
        let root = try scratchRoot()
        let before = realDomainSnapshot()

        let defaults = fixtureDefaults(pinnedTo: root)
        let model = NavigationModel(defaults: defaults)
        let file = try XCTUnwrap(model.library.files.first,
                                 "precondition: the fixture root is discoverable, so there is a row to select")
        model.selection = [file.id]

        XCTAssertEqual(defaults.stringArray(forKey: "lastSelectionFileURLs"),
                       [file.id.absoluteString],
                       "the selection has to actually persist — otherwise this test proves nothing")
        XCTAssertEqual(realDomainSnapshot(), before,
                       "no key the model owns may change in the owner's domain")
    }

    /// An UNPINNED model on an injected domain: view state IS persisted (this is not fixture mode), and
    /// still not into `.standard`.
    ///
    /// Unpinned is the case that used to be impossible to test safely: with `.standard` there is a real
    /// `archiveRootBookmark`, so this would have resolved the owner's granted root and walked ~123k real
    /// corpus files from inside a unit test. An injected suite holds no bookmark, so there is no root.
    func testAnUnpinnedModelPersistsItsViewStateOnlyInTheInjectedDomain() throws {
        let before = realDomainSnapshot()

        let defaults = fixtureDefaults()   // no pin, no bookmark
        let model = NavigationModel(defaults: defaults)
        XCTAssertNil(model.rootStore.root, "precondition: an empty domain grants no root, the owner's or any")

        model.filter.searchText = "isolation-probe"
        model.recompute()   // production write path for `ar.viewState`

        let written = try XCTUnwrap(defaults.data(forKey: "ar.viewState"),
                                    "an unpinned model is not in UI-test mode, so it does persist view state")
        XCTAssertTrue(String(decoding: written, as: UTF8.self).contains("isolation-probe"),
                      "and what it persisted is this test's filter")
        XCTAssertEqual(realDomainSnapshot(), before,
                       "the owner's saved filter and sort must be exactly as they were")
    }
}
