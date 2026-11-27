import XCTest
import AppKit
import SwiftUI
import ArchiveCore
@testable import ArchiveCoreUI

/// The shared Tags window's state (W40.tag-window-core), driven through a fake writer that keeps items in memory
/// and runs each plan as one step, as an app's writer does.
@MainActor
final class TagsWindowModelTests: XCTestCase {

    /// An app's library in memory: `apply` runs a plan on each item's current tags, counts the steps (one per
    /// change, as one Undo) and fails the items listed in `failing`.
    final class FakeLibrary {
        var items: [String: [String]]
        var steps: [TagChangePlan] = []
        var failing: Set<String> = []

        init(_ items: [String: [String]]) { self.items = items }

        var inventory: TagInventory {
            TagInventory(items: items.keys.sorted().map { TagInventory.Item(id: $0, tags: items[$0]!) })
        }

        func apply(_ plan: TagChangePlan) -> TagsWindowModel.Outcome {
            steps.append(plan)
            var changed = 0, failed = 0
            for id in plan.itemIDs {
                guard let tags = items[id], let new = plan.applied(to: tags) else { continue }
                if failing.contains(id) { failed += 1; continue }
                items[id] = new
                changed += 1
            }
            return .init(changed: changed, failed: failed)
        }
    }

    /// The writer's way back to the model, set once the model exists.
    final class Holder { weak var model: TagsWindowModel? }

    private func make(_ items: [String: [String]]) -> (FakeLibrary, TagsWindowModel) {
        let library = FakeLibrary(items)
        let holder = Holder()
        let model = TagsWindowModel(inventory: library.inventory, noun: .file) { plan in
            let outcome = library.apply(plan)
            holder.model?.update(library.inventory)
            return outcome
        }
        holder.model = model
        return (library, model)
    }

    func testRowsSearchAndSort() {
        let (_, model) = make(["a": ["Labor", "Civil Rights", "Q2"], "b": ["labor"], "c": ["Strikes", "Labor"]])
        XCTAssertEqual(model.rows.map(\.name), ["Civil Rights", "Labor", "Strikes"])
        model.sort = .count
        XCTAssertEqual(model.rows.map(\.name), ["Labor", "Civil Rights", "Strikes"])
        model.search = "LAB"
        XCTAssertEqual(model.rows.map(\.name), ["Labor"])
        model.search = "rights"
        XCTAssertEqual(model.rows.map(\.name), ["Civil Rights"])
        XCTAssertEqual(model.suiteTokens.map(\.name), ["Q2"])
    }

    func testFindSimilarGroupsTheVariants() {
        let (_, model) = make(["a": ["Environment"], "b": ["Environment"], "c": ["Environtment"], "d": ["Labor"],
                               "e": ["Jerry Brown"], "f": ["Jery Brown"]])
        model.similarOnly = true
        XCTAssertEqual(model.rows.map(\.name), ["Environment", "Environtment", "Jerry Brown", "Jery Brown"])
        XCTAssertEqual(model.rows.map { model.similarGroup(of: $0) }, [0, 0, 1, 1])
    }

    func testRenameIsOneStepAndKeepsTheResultSelected() async throws {
        let (library, model) = make(["a": ["Labor", "Unread"], "b": ["Labor"], "c": ["Strikes"]])
        let labor = try XCTUnwrap(model.inventory.entry(for: "Labor"))
        model.selection = [labor.id]
        let plan = try XCTUnwrap(model.renamePlan(labor, to: "Labour"))
        let outcome = await model.perform(plan)
        XCTAssertEqual(outcome, .init(changed: 2))
        XCTAssertEqual(library.steps.count, 1)
        XCTAssertEqual(library.items["a"], ["Labour", "Unread"])
        XCTAssertEqual(model.rows.map(\.name), ["Labour", "Strikes"])
        XCTAssertEqual(model.selection, [tagKey("Labour")])
        XCTAssertEqual(model.status, "Renamed “Labor” to “Labour” on 2 files.")
    }

    func testMergeAndRemove() async throws {
        let (library, model) = make(["a": ["Environment"], "b": ["Environtment", "Labor"], "c": ["Enviroment"]])
        let variants = model.rows.filter { $0.name.hasPrefix("Env") }
        let merge = try XCTUnwrap(model.mergePlan(variants, into: "Environment"))
        XCTAssertEqual(merge.itemCount, 2)
        await model.perform(merge)
        XCTAssertEqual(library.items, ["a": ["Environment"], "b": ["Environment", "Labor"], "c": ["Environment"]])
        XCTAssertEqual(model.status, "Merged 3 tags into “Environment” on 2 files.")

        let remove = try XCTUnwrap(model.removePlan([try XCTUnwrap(model.inventory.entry(for: "environment"))]))
        XCTAssertEqual(remove.summary(noun: model.noun), "Remove “Environment” from 3 files")
        await model.perform(remove)
        XCTAssertEqual(library.items, ["a": [], "b": ["Labor"], "c": []])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(library.steps.count, 2)
    }

    func testFailuresAreNamed() async throws {
        let (library, model) = make(["a": ["Labor"], "b": ["Labor"]])
        library.failing = ["b"]
        let plan = try XCTUnwrap(model.removePlan(model.rows))
        await model.perform(plan)
        XCTAssertEqual(model.status, "Removed “Labor” from 1 file. 1 file could not be saved.")
        XCTAssertEqual(model.rows.map(\.name), ["Labor"], "the failed file still carries it")
    }

    func testOneChangeAtATime() async throws {
        let library = FakeLibrary(["a": ["Labor"]])
        let gate = AsyncStream<Void>.makeStream()
        let holder = Holder()
        let model = TagsWindowModel(inventory: library.inventory, noun: .file) { plan in
            for await _ in gate.stream { break }
            let outcome = library.apply(plan)
            holder.model?.update(library.inventory)
            return outcome
        }
        holder.model = model
        let plan = try XCTUnwrap(model.removePlan(model.rows))
        let first = Task { await model.perform(plan) }
        while !model.isWorking { await Task.yield() }
        let second = await model.perform(plan)
        XCTAssertNil(second, "refused while the first runs")
        gate.continuation.yield()
        _ = await first.value
        XCTAssertEqual(library.steps.count, 1)
        XCTAssertFalse(model.isWorking)
    }

    func testExistingTagIsNamedBeforeAMerge() throws {
        let (_, model) = make(["a": ["Jerry Brown"], "b": ["Brown, Jerry"]])
        let jerry = try XCTUnwrap(model.inventory.entry(for: "Jerry Brown"))
        XCTAssertEqual(model.existingTag(named: "brown, jerry", except: [jerry])?.name, "Brown, Jerry")
        XCTAssertNil(model.existingTag(named: "JERRY BROWN", except: [jerry]), "itself is not another tag")
        XCTAssertNil(model.existingTag(named: "New Name", except: [jerry]))
    }

    /// The window lays out headlessly with a list, the suite-token section and an accessory (no window, no screen).
    func testTheWindowLaysOut() {
        let (_, model) = make(["a": ["Labor", "Q2"], "b": ["Strikes"]])
        model.showItems = { _ in }
        let host = NSHostingView(rootView: TagsWindowView(model: model) { Text("Accessory") })
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    /// The Processor's lists name where a tag is held in place of a count (W40.tag-window-processor).
    func testTheCountColumnCanNameTheLists() {
        let (_, model) = make(["Suggestions": ["Labor", "Strikes"], "Subject list": ["Labor"]])
        model.itemsLabel = { $0.itemIDs.sorted().joined(separator: ", ") }
        let labor = model.rows.first { $0.name == "Labor" }!
        XCTAssertEqual(model.itemsLabel?(labor), "Subject list, Suggestions")
        let host = NSHostingView(rootView: TagsWindowView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 420)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }
}
