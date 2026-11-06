import XCTest
import ArchiveCore
@testable import ArchiveReader

/// W40.fix-tags-case-insensitive (owner session reader-1, row 30): tags that differ only in case are one
/// tag. Driven through the `NavigationModel` paths the UI takes, on scratch `mktemp` fixtures only, with the
/// shared ledger pointed at a scratch file per test.
@MainActor
final class TagCaseIdentityTests: XCTestCase {

    private var ledgerURL: URL!
    private var savedLedgerURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        savedLedgerURL = AuditLedger.shared.fileURL
        ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagCaseIdentityTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("audit-ledger.jsonl")
        AuditLedger.shared.fileURL = ledgerURL
    }

    override func tearDown() async throws {
        AuditLedger.shared.fileURL = savedLedgerURL
        try? FileManager.default.removeItem(at: ledgerURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    /// a, c: "Lincoln"; b: "lincoln"; d: no subject.
    private func makeRoot() throws -> (root: URL, files: [URL]) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagCaseIdentityTests-root-\(UUID().uuidString)", isDirectory: true)
        let box = root.appendingPathComponent("Box", isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let tags = [["Unread", "Lincoln"], ["Unread", "lincoln"], ["Unread", "Lincoln"], ["Unread"]]
        let files = try zip(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], tags).map { name, t -> URL in
            let url = box.appendingPathComponent(name)
            try Data("scratch PDF \(name)".utf8).write(to: url)
            try (url as NSURL).setResourceValue(t, forKey: .tagNamesKey)
            return url
        }
        return (root, files)
    }

    /// The model with its subject cache built: `libraryDidChange` refreshes it one main-queue hop after load.
    private func model(_ root: URL, _ testName: String = #function) -> NavigationModel {
        let model = fixtureNavigationModel(pinnedTo: root, testName)
        let deadline = Date().addingTimeInterval(10)
        while model.allSubjects.isEmpty, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return model
    }

    private func tags(_ url: URL) -> [String] {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    func testTheLibraryCountsCaseVariantsAsOneTagInTheMostUsedSpelling() throws {
        let fixture = try makeRoot()
        let model = model(fixture.root)
        XCTAssertEqual(model.allSubjects, ["Lincoln"])
        XCTAssertEqual(model.tagCloud.map(\.tag), ["Lincoln"])
        XCTAssertEqual(model.tagCloud.first?.count, 3)
        XCTAssertEqual(model.affectedFileCount(forTag: "lincoln"), 3)
        XCTAssertEqual(model.subjectFileCounts, ["Lincoln": 3])
    }

    func testANewTagTakesTheLibrarySpelling() throws {
        let fixture = try makeRoot()
        let model = model(fixture.root)
        XCTAssertEqual(model.spellingForNewTag("LINCOLN"), "Lincoln")
        XCTAssertEqual(model.existingSpelling(differingFrom: "lincoln"), "Lincoln")
        XCTAssertNil(model.existingSpelling(differingFrom: "Lincoln"), "typed as spelt: nothing to say")
        XCTAssertNil(model.existingSpelling(differingFrom: "Douglass"))
        let d = try XCTUnwrap(model.library.files.first { $0.url.path == fixture.files[3].path })
        model.applyEdit(.addSubject("LINCOLN"), to: d)
        XCTAssertEqual(Set(tags(fixture.files[3])), ["Unread", "Lincoln"])
        // The file that already has the tag in its own spelling keeps it.
        let b = try XCTUnwrap(model.library.files.first { $0.url.path == fixture.files[1].path })
        model.commitSubjectEdit(from: ["lincoln"], to: ["lincoln", "LINCOLN"], for: b)
        XCTAssertEqual(tags(fixture.files[1]), ["Unread", "lincoln"])
    }

    func testRenamingATagToItsShownSpellingUnifiesTheOthers() throws {
        let fixture = try makeRoot()
        let model = model(fixture.root)
        XCTAssertTrue(model.hasOtherSpellings(of: "Lincoln"))
        model.renameTag(from: "Lincoln", to: "Lincoln")
        XCTAssertEqual(Set(tags(fixture.files[1])), ["Unread", "Lincoln"])
        XCTAssertEqual(tags(fixture.files[0]), ["Unread", "Lincoln"], "a file already spelt so is not rewritten")
        XCTAssertEqual(AuditLedger.shared.entries().map(\.op), [.rename], "one file written")
    }
}
