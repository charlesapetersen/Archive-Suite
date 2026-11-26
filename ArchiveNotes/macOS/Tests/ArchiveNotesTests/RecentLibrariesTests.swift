import XCTest
import AppKit
import ArchiveCore
@testable import ArchiveNotes

/// W49.notes-library-ux — File ▸ Open Recent's list, the open library's name, and New being off with no
/// library. Every library and list here is scratch: a temp folder and a throwaway defaults suite, never the
/// app's own `notesRecentLibraries` or `notesStoreRootBookmark`.
@MainActor
final class RecentLibrariesTests: XCTestCase {

    private var scratch: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let center = NotificationCenter()

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentLibrariesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        suiteName = "com.archivenotes.tests.recent-libraries.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: scratch)
    }

    private func library(_ name: String, in parent: String? = nil) throws -> URL {
        var url = scratch!
        if let parent { url.appendPathComponent(parent, isDirectory: true) }
        url.appendPathComponent(name + ".archivenotes", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try RootMarker.ensure(at: url, kind: .notes, name: name)
        return url
    }

    func testNoteKeepsNewestFirstWithoutDuplicatesAndPersists() throws {
        let a = try library("Alpha"), b = try library("Beta")
        let recents = RecentLibraries(defaults: defaults)
        recents.note(a)
        recents.note(b)
        recents.note(a)
        XCTAssertEqual(recents.entries.map(\.name), ["Alpha", "Beta"], "reopening moves a library to the top, once")
        XCTAssertEqual(RecentLibraries(defaults: defaults).entries.map(\.name), ["Alpha", "Beta"],
                       "the list survives a relaunch")
    }

    func testListIsCappedAtTheLimit() throws {
        let recents = RecentLibraries(defaults: defaults)
        for i in 0..<(RecentLibraries.limit + 3) { recents.note(try library("L\(i)")) }
        XCTAssertEqual(recents.entries.count, RecentLibraries.limit)
        XCTAssertEqual(recents.entries.first?.name, "L\(RecentLibraries.limit + 2)", "the newest is kept")
        XCTAssertFalse(recents.entries.contains { $0.name == "L0" }, "the oldest goes")
    }

    func testClearAndRemove() throws {
        let recents = RecentLibraries(defaults: defaults)
        recents.note(try library("Alpha"))
        recents.note(try library("Beta"))
        recents.remove(try XCTUnwrap(recents.entries.first { $0.name == "Beta" }))
        XCTAssertEqual(recents.entries.map(\.name), ["Alpha"])
        recents.clear()
        XCTAssertTrue(recents.entries.isEmpty)
        XCTAssertTrue(RecentLibraries(defaults: defaults).entries.isEmpty, "Clear Menu is remembered")
    }

    func testInMemoryListWritesNothing() throws {
        let recents = RecentLibraries(defaults: nil)
        recents.note(try library("Alpha"))
        XCTAssertEqual(recents.entries.count, 1)
        XCTAssertNil(defaults.object(forKey: RecentLibraries.key))
    }

    func testResolveFindsTheLibraryAndNotADeletedOne() throws {
        let a = try library("Alpha")
        let recents = RecentLibraries(defaults: defaults)
        recents.note(a)
        let entry = try XCTUnwrap(recents.entries.first)
        let url = try XCTUnwrap(recents.resolve(entry), "a library still there resolves")
        url.stopAccessingSecurityScopedResource()
        XCTAssertEqual(RecentLibraries.canonicalPath(url), RecentLibraries.canonicalPath(a))
        try FileManager.default.removeItem(at: a)
        XCTAssertNil(recents.resolve(entry), "a deleted library is reported as missing, not opened")
    }

    func testTitleNamesThePlaceOnlyWhenTwoLibrariesShareAName() throws {
        let recents = RecentLibraries(defaults: defaults)
        recents.note(try library("Notes", in: "One"))
        recents.note(try library("Other"))
        XCTAssertEqual(recents.entries.map { recents.title(for: $0) }, ["Other", "Notes"])
        recents.note(try library("Notes", in: "Two"))
        let titles = recents.entries.map { recents.title(for: $0) }
        XCTAssertTrue(titles[0].hasPrefix("Notes — ") && titles[0].hasSuffix("/Two"), "\(titles)")
        XCTAssertTrue(titles[2].hasPrefix("Notes — ") && titles[2].hasSuffix("/One"), "\(titles)")
        XCTAssertEqual(titles[1], "Other")
    }

    /// A launch that opens a library puts it on the list; one whose library is refused does not.
    func testLaunchRecordsTheLibraryItOpens() throws {
        let a = try library("Alpha")
        defaults.set(try a.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                        relativeTo: nil), forKey: "notesStoreRootBookmark")
        let store = RootFolderStore(defaults: defaults, notificationCenter: center)
        XCTAssertNotNil(store.root)
        XCTAssertEqual(store.recentLibraries.entries.map(\.name), ["Alpha"])

        let plain = scratch.appendingPathComponent("Plain folder", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: plain.appendingPathComponent("stuff"),
                                                withIntermediateDirectories: true)
        defaults.set(try plain.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                            relativeTo: nil), forKey: "notesStoreRootBookmark")
        let refused = RootFolderStore(defaults: defaults, notificationCenter: center)
        XCTAssertNil(refused.root)
        XCTAssertEqual(refused.recentLibraries.entries.map(\.name), ["Alpha"], "a refused folder is not listed")
    }

    func testFirstLaunchHasNoLibraryOpen() {
        let store = RootFolderStore(defaults: defaults, notificationCenter: center)
        XCTAssertNil(store.root)
        XCTAssertTrue(store.needsLibrary)
        XCTAssertTrue(store.recentLibraries.entries.isEmpty)
    }

    func testInjectedModelCountsAsOpenAndHasNoLibraryName() {
        let model = NotesModel(organization: OrganizationStore(index: NotesIndex(url: scratch
            .appendingPathComponent("idx.sqlite3"))))
        XCTAssertTrue(model.isLibraryOpen, "an injected test store can always make items")
        XCTAssertNil(model.libraryName)
        XCTAssertNil(model.recentLibraries)
    }
}
