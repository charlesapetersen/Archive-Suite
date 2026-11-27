import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W49.reader-ux-gaps-small: the Read + Unread health filter, an excluded folder outside the root, and File ▸ Open
/// Recent. Every store here gets a throwaway defaults suite: `setRoot(bookmark:)` writes `archiveRootBookmark`.
@MainActor
final class ReaderUXGapsTests: XCTestCase {

    private func file(_ name: String, _ tags: [String]) -> ArchiveFile {
        ArchiveFile(url: URL(fileURLWithPath: "/corpus/\(name)"), name: name, fileType: "PDF",
                    tags: DocumentTags.parse(raw: tags, labelNumber: nil), contentModified: nil)
    }

    private func scratchDir(_ name: String = #function) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("UXGaps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: Both Read and Unread

    func testTheReadAndUnreadFilterShowsWhatTheHealthCountCounts() {
        let both = file("a", ["Read", "Unread", "1980"])
        let lower = file("b", ["read", "UNREAD"])
        let read = file("c", ["Read"])
        let unread = file("d", ["Unread"])
        XCTAssertTrue(both.hasBothReadStates)
        XCTAssertTrue(lower.hasBothReadStates, "in any case, as the count has always matched")
        XCTAssertFalse(read.hasBothReadStates)

        var f = LibraryFilter()
        XCTAssertFalse(f.isActive)
        f.bothReadStatesOnly = true
        XCTAssertTrue(f.isActive)
        XCTAssertEqual([both, lower, read, unread].filter(f.matches).map(\.name), ["a", "b"])

        let chips = ActiveFilterChip.chips(filter: f, smartFolderName: nil, fullTextQuery: nil)
        XCTAssertEqual(chips.map(\.facet), [.bothReadStates])
        XCTAssertEqual(chips.first?.accessibilityIdentifier, "ar.filter.bothReadStates")
        XCTAssertFalse(f.removing(.bothReadStates).isActive, "the chip's × clears it")
    }

    func testTheReadAndUnreadFilterSavesAsARule() {
        var f = LibraryFilter(); f.bothReadStatesOnly = true
        let search = AdvancedSearch(filter: f, fullTextQuery: "")
        XCTAssertEqual(search.rules.map(\.field), [.bothReadStates])
        XCTAssertTrue(search.matches(file("a", ["Read", "Unread"]), RuleContext()))
        XCTAssertFalse(search.matches(file("b", ["Read"]), RuleContext()))
        let not = AdvancedSearch(combine: .all, rules: [SearchRule(field: .bothReadStates, op: .isNot)])
        XCTAssertTrue(not.matches(file("b", ["Read"]), RuleContext()))
    }

    func testAFilterSavedBeforeTheFieldStillDecodes() throws {
        let old = try JSONEncoder().encode(LibraryFilter())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "bothReadStates")
        let decoded = try JSONDecoder().decode(LibraryFilter.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.bothReadStatesOnly)
    }

    // MARK: Excluded folders

    func testAFolderOutsideTheRootIsRefusedAndSaysWhy() {
        typealias P = ExcludedFoldersStore.Placement
        XCTAssertEqual(ExcludedFoldersStore.placement(of: "/r/Archive/Box 1", rootPath: "/r/Archive"), P.inside("Box 1"))
        XCTAssertEqual(ExcludedFoldersStore.placement(of: "/r/Archive/Box 1/A/", rootPath: "/r/Archive/"),
                       P.inside("Box 1/A"))
        XCTAssertEqual(ExcludedFoldersStore.placement(of: "/r/Archive", rootPath: "/r/Archive/"), P.isRoot)
        XCTAssertEqual(ExcludedFoldersStore.placement(of: "/r/Archive2/Box", rootPath: "/r/Archive"), P.outside,
                       "a sibling whose name starts with the root's is outside it")
        XCTAssertEqual(ExcludedFoldersStore.placement(of: "/elsewhere", rootPath: "/r/Archive"), P.outside)

        XCTAssertNil(ExcludedFoldersStore.refusal(.inside("Box"), folderName: "Box", rootName: "Archive"))
        let outside = ExcludedFoldersStore.refusal(.outside, folderName: "Downloads", rootName: "Archive") ?? ""
        XCTAssertTrue(outside.contains("“Downloads” is not inside the archive folder “Archive”"), outside)
        let root = ExcludedFoldersStore.refusal(.isRoot, folderName: "Archive", rootName: "Archive") ?? ""
        XCTAssertTrue(root.contains("archive folder itself"), root)
    }

    func testTheSidebarRefusesAFolderOutsideTheRootAndAddsNothing() throws {
        let root = try scratchDir()
        let defaults = fixtureDefaults(pinnedTo: root)
        let model = NavigationModel(defaults: defaults)
        XCTAssertNotNil(model.rootStore.discoveredPathPrefix, "precondition: the fixture root is open")
        model.excludeFolder("/elsewhere/Box")
        XCTAssertEqual(model.excludedFolders.excludedRelativePaths, [])
        XCTAssertTrue(model.statusMessage.contains("is not inside the archive folder"), model.statusMessage)
    }

    // MARK: Open Recent

    func testRecentFoldersAreNewestFirstWithoutRepeatsAndCapped() {
        func entry(_ p: String) -> RecentArchiveFolder { RecentArchiveFolder(path: p, bookmark: Data(p.utf8)) }
        var list: [RecentArchiveFolder] = []
        for n in 0..<12 { list = RecentArchiveFolders.noting(entry("/a/\(n)"), in: list) }
        XCTAssertEqual(list.count, RecentArchiveFolders.limit)
        XCTAssertEqual(list.first?.path, "/a/11")
        list = RecentArchiveFolders.noting(entry("/a/5"), in: list)
        XCTAssertEqual(list.map(\.path).filter { $0 == "/a/5" }.count, 1, "reopening moves it, never repeats it")
        XCTAssertEqual(list.first?.path, "/a/5")
        XCTAssertEqual(list.first?.name, "5")
        XCTAssertEqual(RecentArchiveFolders.decode(Data("junk".utf8)), [], "an unreadable list is an empty menu")
    }

    func testAFolderNotedIsListedAndReopensThroughItsBookmark() throws {
        let defaults = fixtureDefaults()
        let first = try scratchDir().appendingPathComponent("First", isDirectory: true)
        let second = try scratchDir().appendingPathComponent("Second", isDirectory: true)
        for dir in [first, second] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let standardBookmark = UserDefaults.standard.data(forKey: "archiveRootBookmark")

        RecentArchiveFolders.note(first, in: defaults)
        RecentArchiveFolders.note(second, in: defaults)
        let recent = RecentArchiveFolders.list(in: defaults)
        XCTAssertEqual(recent.map(\.name), ["Second", "First"])

        let store = RootFolderStore(defaults: defaults)
        XCTAssertNil(store.root)
        let entry = try XCTUnwrap(recent.last)
        XCTAssertNil(store.setRoot(bookmark: entry.bookmark, name: entry.name))
        XCTAssertEqual(store.root?.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent, "First")
        XCTAssertNotNil(store.discoveredPathPrefix)
        XCTAssertTrue(store.hasSavedBookmark, "an opened recent folder is the folder reopened at the next launch")
        XCTAssertEqual(UserDefaults.standard.data(forKey: "archiveRootBookmark"), standardBookmark,
                       "never the owner's real root")

        RecentArchiveFolders.remove(path: entry.path, in: defaults)
        XCTAssertEqual(RecentArchiveFolders.list(in: defaults).map(\.name), ["Second"])
        RecentArchiveFolders.clear(in: defaults)
        XCTAssertEqual(RecentArchiveFolders.list(in: defaults), [])
    }

    func testARecentFolderThatIsGoneSaysSoAndChangesNothing() throws {
        let defaults = fixtureDefaults()
        let kept = try scratchDir()
        let store = RootFolderStore(defaults: defaults)
        XCTAssertNil(store.setRoot(kept))
        let saved = defaults.data(forKey: "archiveRootBookmark")

        let gone = try scratchDir().appendingPathComponent("Gone", isDirectory: true)
        try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
        let bookmark = try gone.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                             relativeTo: nil)
        try FileManager.default.removeItem(at: gone)

        for data in [bookmark, Data("not a bookmark".utf8)] {
            let refusal = store.setRoot(bookmark: data, name: "Gone")
            XCTAssertEqual(refusal, .recentUnavailable("Gone"))
            XCTAssertTrue(refusal?.message.contains("Could not open “Gone”") == true)
            XCTAssertEqual(store.root, CorpusWalker.canonicalRoot(kept), "the folder showing stays")
            XCTAssertEqual(defaults.data(forKey: "archiveRootBookmark"), saved, "and stays the one reopened")
        }
    }
}
