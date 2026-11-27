import XCTest
import ArchiveCore

/// W40.tag-window-processor — a Tags window change made to a list of spellings (the Processor's two vocabularies),
/// undone and redone on a list that changed in between.
final class TagSpellingChangeTests: XCTestCase {

    /// The Processor's lists as the window's items: a plan made on them, applied to one list.
    private func plan(_ lists: [String: [String]], _ make: (TagInventory) -> TagChangePlan?) throws -> TagChangePlan {
        let inventory = TagInventory(items: lists.keys.sorted().map { TagInventory.Item(id: $0, tags: lists[$0]!) })
        return try XCTUnwrap(make(inventory))
    }

    func testRenameUndoRedo() throws {
        let list = ["Labor", "Strikes", "Civil Rights"]
        let rename = try plan(["l": list]) { $0.renamePlan("Labor", to: "Labour") }
        let new = try XCTUnwrap(rename.applied(to: list))
        XCTAssertEqual(new, ["Labour", "Strikes", "Civil Rights"])
        let change = try XCTUnwrap(TagSpellingChange(from: list, to: new))
        XCTAssertEqual(change.applied(to: list), new)
        XCTAssertEqual(change.inverse.applied(to: new), list)
        XCTAssertEqual(change.spellings, [tagKey("Labor"): nil, tagKey("Labour"): "Labour"])
    }

    func testUndoKeepsWhatWasAddedSince() throws {
        let list = ["Labor", "Strikes"]
        let change = try XCTUnwrap(TagSpellingChange(from: list, to: ["Labour", "Strikes"]))
        // The user added a tag and moved things after the rename; Undo moves only the renamed one.
        let since = ["Strikes", "Taxes", "Labour"]
        XCTAssertEqual(change.inverse.applied(to: since), ["Strikes", "Taxes", "Labor"])
        // Redo on that list.
        XCTAssertEqual(change.applied(to: ["Strikes", "Taxes", "Labor"]), ["Strikes", "Taxes", "Labour"])
    }

    func testRemoveAndUndoPutsItBackWhereItStood() throws {
        let list = ["Civil Rights", "Labor", "Strikes"]
        let remove = try plan(["l": list]) { $0.removePlan(["Labor"]) }
        let new = try XCTUnwrap(remove.applied(to: list))
        XCTAssertEqual(new, ["Civil Rights", "Strikes"])
        let change = try XCTUnwrap(TagSpellingChange(from: list, to: new))
        XCTAssertEqual(change.inverse.applied(to: new), list)
        // A list that shrank since: the tag goes back at the end at most.
        XCTAssertEqual(change.inverse.applied(to: []), ["Labor"])
    }

    func testMergeIntoAnExistingTagAndUndo() throws {
        let list = ["Environment", "Environtment", "Labor", "Enviroment"]
        let merge = try plan(["l": list]) { $0.mergePlan(["Environtment", "Enviroment"], into: "environment") }
        XCTAssertEqual(merge.target, "Environment")
        let new = try XCTUnwrap(merge.applied(to: list))
        XCTAssertEqual(new, ["Environment", "Labor"])
        let change = try XCTUnwrap(TagSpellingChange(from: list, to: new))
        XCTAssertNil(change.steps[tagKey("Environment")], "the target was there before and is unchanged")
        XCTAssertEqual(change.inverse.applied(to: new), list)
    }

    func testCaseOnlyRespellingAndNoChange() throws {
        let change = try XCTUnwrap(TagSpellingChange(from: ["labor", "Strikes"], to: ["Labor", "Strikes"]))
        XCTAssertEqual(change.steps.count, 1)
        XCTAssertEqual(change.inverse.applied(to: ["Labor", "Strikes"]), ["labor", "Strikes"])
        XCTAssertNil(TagSpellingChange(from: ["Labor"], to: ["Labor"]))
        XCTAssertNil(TagSpellingChange(from: [], to: []))
    }

    func testVocabularyAppliesAndUndoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("TagSpelling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let vocabulary = TagVocabulary(fileURL: dir.appendingPathComponent("vocab.json"))
        vocabulary.add(rawTags: ["Labor", "Strikes", "Environtment", "Environment"])
        let before = vocabulary.snapshot()
        let merge = try plan(["v": before]) { $0.mergePlan(["Labor", "Strikes"], into: "Labour") }
        let change = try XCTUnwrap(TagSpellingChange(from: before, to: try XCTUnwrap(merge.applied(to: before))))
        XCTAssertTrue(vocabulary.apply(change))
        XCTAssertEqual(vocabulary.snapshot(), ["Environment", "Environtment", "Labour"])
        vocabulary.add(rawTags: ["Taxes"])   // added in between
        XCTAssertTrue(vocabulary.apply(change.inverse))
        XCTAssertEqual(vocabulary.snapshot(), ["Environment", "Environtment", "Labor", "Strikes", "Taxes"])
        XCTAssertFalse(vocabulary.apply(change.inverse), "applying it twice changes nothing")
        vocabulary.flush()
        XCTAssertEqual(TagVocabulary(fileURL: dir.appendingPathComponent("vocab.json")).snapshot(),
                       ["Environment", "Environtment", "Labor", "Strikes", "Taxes"])
    }
}
