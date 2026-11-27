import XCTest
@testable import ArchiveCore

/// `TagInventory` and its change plans (W40.tag-window-core): pure, on in-memory items, then executed on scratch
/// files through `CoordinatedTagWriter` the way an app's writer runs them (never the corpus).
final class TagInventoryTests: XCTestCase {

    private func inventory(_ items: [(String, [String])]) -> TagInventory {
        TagInventory(items: items.map { TagInventory.Item(id: $0.0, tags: $0.1) })
    }

    // MARK: The inventory

    func testCountsEachTagOncePerItemAcrossSpellings() throws {
        let inv = inventory([("a", ["Civil Rights", "Unread", "civil rights"]),
                             ("b", ["Civil Rights", "Labor"]),
                             ("c", ["civil rights"])])
        let civil = try XCTUnwrap(inv.entry(for: "CIVIL RIGHTS"))
        XCTAssertEqual(civil.itemCount, 3)
        XCTAssertEqual(civil.itemIDs, ["a", "b", "c"])
        XCTAssertEqual(civil.name, "Civil Rights", "a tie goes to the spelling that sorts first")
        XCTAssertEqual(civil.spellings.map(\.tag), ["Civil Rights", "civil rights"])
        XCTAssertTrue(civil.hasVariantSpellings)
        XCTAssertEqual(inv.subjects.map(\.name), ["Civil Rights", "Labor"])
        XCTAssertEqual(inv.suiteTokens.map(\.name), ["Unread"])
    }

    func testSuiteTokensAreListedApart() {
        for token in ["Q2", "P9", "1987", "1970s", "3 March", "Day 15", "Date Uncertain", "Read", "unread", "Box",
                      "Folder", "Red", "Checked Date", "OCR Poor", "OCR Failed", "Sent With 1958-03-12"] {
            XCTAssertTrue(TagInventory.isSuiteToken(token), token)
        }
        for subject in ["q2", "red", "box", "Civil Rights", "Labor", "Environment"] {
            XCTAssertFalse(TagInventory.isSuiteToken(subject), subject)
        }
        let inv = inventory([("a", ["Q2", "q2", "Red", "red"])])
        XCTAssertEqual(Set(inv.subjects.map(\.name)), ["q2", "red"])
        XCTAssertEqual(Set(inv.suiteTokens.map(\.name)), ["Q2", "Red"])
    }

    func testSimilarClustersGroupDifferentTags() {
        let inv = inventory([("a", ["Environment"]), ("b", ["Environment"]), ("c", ["Environtment"]),
                             ("d", ["Labor"])])
        let clusters = inv.similarClusters()
        XCTAssertEqual(clusters.map { $0.map(\.name) }, [["Environment", "Environtment"]])
    }

    // MARK: Plans on in-memory items

    func testRenameIntoNewName() throws {
        let inv = inventory([("a", ["Unread", "Civil Rights", "Labor"]), ("b", ["Labor"])])
        let plan = try XCTUnwrap(inv.renamePlan("civil rights", to: "  Civil Rights Movement "))
        XCTAssertEqual(plan.kind, .rename)
        XCTAssertEqual(plan.target, "Civil Rights Movement")
        XCTAssertEqual(plan.itemIDs, ["a"])
        XCTAssertEqual(plan.applied(to: ["Unread", "Civil Rights", "Labor"]),
                       ["Unread", "Civil Rights Movement", "Labor"], "in place; nothing else moves")
        XCTAssertNil(plan.applied(to: ["Labor"]))
        XCTAssertEqual(plan.summary(noun: .file), "Rename “Civil Rights” to “Civil Rights Movement” on 1 file")
    }

    func testRenameIntoExistingTagMergesIntoItsSpelling() throws {
        let inv = inventory([("a", ["Jerry Brown"]), ("b", ["Brown, Jerry", "Q1"]), ("c", ["Brown, Jerry"]),
                             ("d", ["Jerry Brown", "brown, jerry"])])
        let plan = try XCTUnwrap(inv.renamePlan("Jerry Brown", to: "BROWN, JERRY"))
        XCTAssertEqual(plan.target, "Brown, Jerry", "the existing tag's spelling")
        XCTAssertEqual(plan.itemIDs, ["a", "d"])
        XCTAssertEqual(plan.applied(to: ["Jerry Brown"]), ["Brown, Jerry"])
        XCTAssertEqual(plan.applied(to: ["Jerry Brown", "brown, jerry"]), ["brown, jerry"],
                       "an item that already carries the target keeps its own token")
    }

    func testCaseOnlyRenameRespellsEverySpelling() throws {
        let inv = inventory([("a", ["civil rights"]), ("b", ["Civil rights", "CIVIL RIGHTS"]), ("c", ["Civil Rights"])])
        let plan = try XCTUnwrap(inv.renamePlan("civil rights", to: "Civil Rights"))
        XCTAssertEqual(plan.itemIDs, ["a", "b"], "c is already spelled so")
        XCTAssertEqual(plan.applied(to: ["Civil rights", "X", "CIVIL RIGHTS"]), ["Civil Rights", "X"])
        XCTAssertNil(inventory([("a", ["Labor"])]).renamePlan("Labor", to: "Labor"), "nothing would change")
    }

    func testMergeSeveralIntoOneOfThem() throws {
        let inv = inventory([("a", ["Environment"]), ("b", ["Environtment", "Labor"]), ("c", ["environment"]),
                             ("d", ["Enviroment", "Environment"]), ("e", ["Labor"])])
        let plan = try XCTUnwrap(inv.mergePlan(["Environtment", "Enviroment", "Environment"], into: "Environment"))
        XCTAssertEqual(plan.kind, .merge)
        XCTAssertEqual(plan.itemIDs, ["b", "c", "d"])
        XCTAssertEqual(plan.applied(to: ["Environtment", "Labor"]), ["Environment", "Labor"])
        XCTAssertEqual(plan.applied(to: ["environment"]), ["Environment"], "the chosen spelling throughout")
        XCTAssertEqual(plan.applied(to: ["Enviroment", "Environment"]), ["Environment"], "once")
        XCTAssertEqual(plan.logEntries(app: TagChangeLog.notes).map { "\($0.from)>\($0.to)" },
                       ["Environtment>Environment", "Enviroment>Environment"],
                       "the chosen tag itself is not an entry")
    }

    func testRemoveTakesEverySpellingAndNothingElse() throws {
        let inv = inventory([("a", ["Labor", "Q2", "Unread"]), ("b", ["labor"]), ("c", ["Strikes"])])
        let plan = try XCTUnwrap(inv.removePlan(["LABOR"]))
        XCTAssertEqual(plan.itemIDs, ["a", "b"])
        XCTAssertEqual(plan.applied(to: ["Labor", "Q2", "Unread"]), ["Q2", "Unread"])
        XCTAssertEqual(plan.applied(to: ["labor"]), [])
        XCTAssertEqual(plan.logEntries(app: TagChangeLog.reader).map { "\($0.from)>\($0.to)" }, ["Labor>"],
                       "a remove is recorded with an empty to (schema 2)")
        XCTAssertEqual(plan.summary(noun: .file), "Remove “Labor” from 2 files")
    }

    func testSuiteTokensAreNeverPlanned() {
        let inv = inventory([("a", ["Q2", "Labor", "Unread", "1987"])])
        XCTAssertNil(inv.renamePlan("Q2", to: "Important"))
        XCTAssertNil(inv.removePlan(["Unread"]))
        XCTAssertNil(inv.mergePlan(["Labor", "1987"], into: "Labor"))
        XCTAssertNil(inv.renamePlan("Labor", to: "Q3"), "nor renamed into one")
        XCTAssertNil(inv.renamePlan("Labor", to: "   "))
        XCTAssertNil(inv.renamePlan("Absent", to: "Labor"))
    }

    func testAPaddedTokenIsItsOwnTagAsEverywhereInTheSuite() throws {
        let inv = inventory([("a", [" Labor"]), ("b", ["Labor"])])
        XCTAssertEqual(inv.subjects.count, 2, "tagKey does not trim")
        let padded = try XCTUnwrap(inv.subjects.first { $0.name == " Labor" })
        let plan = try XCTUnwrap(inv.renamePlan(padded.name, to: "Labor"))
        XCTAssertEqual(plan.itemIDs, ["a"])
        XCTAssertEqual(plan.applied(to: [" Labor", "Strikes"]), ["Labor", "Strikes"])
        XCTAssertNil(try XCTUnwrap(inv.renamePlan("Labor", to: "Labour")).applied(to: [" Labor"]),
                     "renaming the unpadded tag leaves the padded one alone, as the Reader's rename does")
    }

    func testTheAppsSpellingRuleShapesThePlan() throws {
        let titled = TagInventory(items: [.init(id: "a", tags: ["Civil Rights"]), .init(id: "b", tags: ["Labor"])],
                                  spell: { $0.capitalized })
        XCTAssertNil(titled.renamePlan("Civil Rights", to: "civil rights"), "Notes would title-case it straight back")
        let plan = try XCTUnwrap(titled.renamePlan("Labor", to: "labor history"))
        XCTAssertEqual(plan.target, "Labor History")
        XCTAssertEqual(plan.logEntries(app: TagChangeLog.notes).map(\.to), ["Labor History"])
        XCTAssertEqual(try XCTUnwrap(titled.renamePlan("Labor", to: "civil rights")).target, "Civil Rights",
                       "an existing tag keeps its spelling")
    }

    // MARK: Executed on scratch files

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TagInventoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    private func makeFile(_ name: String, tags: [String]) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("PDF-BYTES-\(name)".utf8).write(to: url)
        if !tags.isEmpty { try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey) }
        return url
    }

    private func tags(_ url: URL) throws -> [String] {
        (try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
    }

    /// A test writer: the plan's `applied(to:)` run on each file's fresh read inside the coordinated write.
    private func execute(_ plan: TagChangePlan, on files: [String: URL]) throws -> Int {
        var changed = 0
        for id in plan.itemIDs {
            let url = try XCTUnwrap(files[id])
            let result = try CoordinatedTagWriter.write(url) { tags, label in plan.applied(to: tags).map { ($0, label) } }
            if !result.isNoOp { changed += 1 }
        }
        return changed
    }

    private func scanned(_ files: [String: URL]) throws -> TagInventory {
        TagInventory(items: try files.keys.sorted().map { TagInventory.Item(id: $0, tags: try tags(files[$0]!)) })
    }

    func testRenameMergeAndRemoveOnScratchFiles() throws {
        let files = [
            "a": try makeFile("a.pdf", tags: ["Unread", "Environment", "Labor"]),
            "b": try makeFile("b.pdf", tags: ["Environtment", "Q2"]),
            "c": try makeFile("c.pdf", tags: ["labor", "1987"]),
            "d": try makeFile("d.pdf", tags: ["Strikes"]),
        ]
        // Merge the typo into the main spelling.
        let merge = try XCTUnwrap(try scanned(files).mergePlan(["Environtment", "Environment"], into: "Environment"))
        XCTAssertEqual(try execute(merge, on: files), 1)
        XCTAssertEqual(try tags(files["b"]!), ["Environment", "Q2"])
        // Rename into an existing tag.
        let rename = try XCTUnwrap(try scanned(files).renamePlan("Strikes", to: "LABOR"))
        XCTAssertEqual(rename.target, "Labor")
        XCTAssertEqual(try execute(rename, on: files), 1)
        XCTAssertEqual(try tags(files["d"]!), ["Labor"])
        // Remove every spelling.
        let remove = try XCTUnwrap(try scanned(files).removePlan(["Labor"]))
        XCTAssertEqual(remove.itemIDs, ["a", "c", "d"])
        XCTAssertEqual(try execute(remove, on: files), 3)
        XCTAssertEqual(try tags(files["a"]!), ["Unread", "Environment"])
        XCTAssertEqual(try tags(files["c"]!), ["1987"])
        XCTAssertEqual(try tags(files["d"]!), [])
        XCTAssertNil(try scanned(files).entry(for: "labor"))
    }

    func testATagAddedSinceThePlanSurvivesItsWrite() throws {
        let url = try makeFile("a.pdf", tags: ["Labor"])
        let plan = try XCTUnwrap(try scanned(["a": url]).renamePlan("Labor", to: "Labour"))
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Labor", "Added Later"], forKey: .tagNamesKey)
        XCTAssertEqual(try execute(plan, on: ["a": url]), 1)
        XCTAssertEqual(try tags(url), ["Labour", "Added Later"])
    }

    func testAFileThatLostTheTagSinceThePlanIsNotWritten() throws {
        let url = try makeFile("a.pdf", tags: ["Labor"])
        let plan = try XCTUnwrap(try scanned(["a": url]).removePlan(["Labor"]))
        try (URL(fileURLWithPath: url.path) as NSURL).setResourceValue(["Strikes"], forKey: .tagNamesKey)
        XCTAssertEqual(try execute(plan, on: ["a": url]), 0)
        XCTAssertEqual(try tags(url), ["Strikes"])
    }
}
