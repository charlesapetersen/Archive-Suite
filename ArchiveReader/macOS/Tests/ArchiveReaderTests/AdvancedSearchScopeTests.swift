import XCTest
import ArchiveCore
import AppKit
import SwiftUI
@testable import ArchiveReader

/// W40.reader-advanced-search: an Advanced Search as the list's base scope — run unsaved, narrowed by the filter
/// bar, saved as a smart folder, edited, counted and deleted — over a scratch fixture with a real content index.
@MainActor
final class AdvancedSearchScopeTests: XCTestCase {
    func testAdvancedSearchScopesTheListLikeASmartFolder() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdvancedSearchScope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let fixture: [(name: String, tags: [String], body: String)] = [
            ("a.pdf", ["Unread", "Press"], "a balanced budget"),
            ("b.pdf", ["Read", "Treasury"], "a draft budget"),
            ("c.pdf", ["Unread"], "taxes"),
            ("d.pdf", ["Read", "Press"], "nothing here"),
        ]
        for f in fixture {
            let url = scratch.appendingPathComponent(f.name)
            try Data("scratch fixture".utf8).write(to: url)
            try (url as NSURL).setResourceValue(f.tags, forKey: .tagNamesKey)
        }
        let bodies = Dictionary(uniqueKeysWithValues: fixture.map { ($0.name, $0.body) })
        let indexer = ContentIndexer(
            url: scratch.appendingPathComponent("content.sqlite3"),
            extractPDFForTesting: { url in
                let body = bodies[url.lastPathComponent] ?? ""
                return ExtractedContent(fullBody: body, strippedBody: body, classification: nil, pageCount: 2)
            }
        )
        let model = NavigationModel(defaults: fixtureDefaults(pinnedTo: scratch), indexer: indexer)
        XCTAssertEqual(model.library.files.count, 4, "precondition: the fixture root supplies four rows")
        let indexDeadline = Date().addingTimeInterval(10)
        while Date() < indexDeadline, indexer.completedPassesForTesting == 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        func shown() -> [String] { model.displayed.map(\.name).sorted() }
        func waitFor(_ want: [String], _ message: String) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, shown() != want { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(shown(), want, message)
        }
        model.clearUserFilters()
        try await waitFor(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], "precondition: nothing filtered")
        XCTAssertFalse(model.clearAllHelp.contains("own rules"), "outside a scope there are no folder rules to return to")

        // OCR text has "budget", and no text has "draft".
        var budget = SearchRule(field: .ocrText); budget.text = "budget"
        var noDraft = SearchRule(field: .text, op: .noWords); noDraft.text = "draft"
        let search = AdvancedSearch(combine: .all, rules: [budget, noDraft, SearchRule(field: .date)])
        model.runAdvancedSearch(search)
        try await waitFor(["a.pdf"], "the text rules, answered by the index")
        XCTAssertFalse(model.scopeIsSaved)
        XCTAssertEqual(model.activeFilterChips.first?.facet, .smartFolder)
        XCTAssertEqual(model.sort.first?.field, .relevance, "text rules sort by relevance")
        let aPath = try XCTUnwrap(model.displayed.first?.path)
        XCTAssertNil(model.searchSnippet(for: aPath), "scope rules select files without preview snippets")

        // The filter bar narrows within it, and Clear goes back to it.
        model.filter.read = .read
        model.recompute()
        XCTAssertEqual(shown(), [])
        model.clearUserFilters()
        XCTAssertEqual(shown(), ["a.pdf"])
        XCTAssertEqual(model.sort.first?.field, .relevance, "Clear keeps the scope's relevance order")
        XCTAssertTrue(model.clearAllHelp.contains("the Advanced Search's own rules"),
                      "W40.fix-reader-clear-all: inside a scope, Clear All's tooltip says it returns to the scope's rules")

        // Saved with a filter-bar narrowing, then opened: the same rows.
        model.filter.subjects = ["press"]
        model.recompute()
        model.saveCurrentSearch(name: "Budget")
        let saved = try XCTUnwrap(model.savedSearches.searches.first { $0.name == "Budget" })
        XCTAssertEqual(saved.search.rules.last?.field, .tags)
        model.applyScope(saved)
        XCTAssertTrue(model.scopeIsSaved)
        try await waitFor(["a.pdf"], "the saved smart folder shows what was saved")

        let textCountDeadline = Date().addingTimeInterval(5)
        while Date() < textCountDeadline, model.smartFolderCounts[saved.id] != 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.smartFolderCounts[saved.id], 1, "text and negative text rules count the actual base set")
        XCTAssertNil(model.searchSnippet(for: aPath), "opening a saved text rule lists filenames only")

        model.fullTextQuery = "balanced"
        model.runFullTextSearch()
        let queryDeadline = Date().addingTimeInterval(5)
        while Date() < queryDeadline, model.searchSnippet(for: aPath) == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let snippet = try XCTUnwrap(model.searchSnippet(for: aPath))
        XCTAssertEqual(snippet.filter(\.isMatch).map(\.text), ["balanced"], "the user's query supplies the preview")
        let nameField = NSTextField(labelWithString: "")
        try renderName(model, field: nameField, path: aPath, named: "smart-folder-search", expectsSnippet: true)
        model.clearUserFilters()
        XCTAssertNil(model.searchSnippet(for: aPath), "Clear returns to plain smart-folder filenames")
        try renderName(model, field: nameField, path: aPath, named: "smart-folder-files", expectsSnippet: false)
        XCTAssertEqual(shown(), ["a.pdf"])

        // A rename keeps the rows, their index answers and the user's sort.
        model.sort = [ARSortDescriptor(field: .name)]
        model.savedSearches.rename(saved.id, to: "Budget memo")
        let renameDeadline = Date().addingTimeInterval(5)
        while Date() < renameDeadline, model.scope?.name != "Budget memo" { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.scope?.name, "Budget memo")
        XCTAssertEqual(shown(), ["a.pdf"], "no flash of the unfiltered list")
        XCTAssertEqual(model.sort.first?.field, .name, "a rename leaves the sort alone")

        // Edit Smart Folder: any of — has none of Press, or is unread.
        var noPress = SearchRule(field: .tags, op: .hasNone); noPress.tags = ["Press"]
        var unread = SearchRule(field: .readState); unread.read = .unread
        model.updateSmartFolder(saved.id, search: AdvancedSearch(combine: .any, rules: [noPress, unread]))
        XCTAssertEqual(shown(), ["a.pdf", "b.pdf", "c.pdf"], "the open folder shows its new rules at once")
        let countDeadline = Date().addingTimeInterval(5)
        while Date() < countDeadline, model.smartFolderCounts[saved.id] != 3 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.smartFolderCounts[saved.id], 3, "a folder with no text rule is counted")

        // A Flagged rule follows a flag change at once.
        model.updateSmartFolder(saved.id, search: AdvancedSearch(combine: .all, rules: [SearchRule(field: .flagged)]))
        XCTAssertEqual(shown(), [])
        let dPath = try XCTUnwrap(model.library.files.first { $0.name == "d.pdf" }?.path)
        model.flags.setFlag(true, for: dPath)
        try await waitFor(["d.pdf"], "flagging a file brings it into a Flagged folder")

        model.savedSearches.delete(saved.id)
        try await waitFor(["a.pdf", "b.pdf", "c.pdf", "d.pdf"], "deleting the open folder leaves it")
        XCTAssertNil(model.scope)
        XCTAssertNotEqual(model.sort.first?.field, .relevance, "leaving a text scope leaves its relevance order")

        // An Advanced Search with nothing filled in leaves the scope rather than showing a chip for nothing.
        model.runAdvancedSearch(.starter)
        XCTAssertNil(model.scope)
        await indexer.closeForTesting()
    }

    func testCountsFollowSavedRulesAndIndexChangesIndependentlyOfUserFilters() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("SmartCounts-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let nested = scratch.appendingPathComponent("Sub")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let a = scratch.appendingPathComponent("a.pdf"), b = nested.appendingPathComponent("b.pdf")
        for (url, text, tags) in [(a, "budget", ["Unread"]), (b, "draft", ["Read", "Press"])] {
            try Data(text.utf8).write(to: url)
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
        }
        let defaults = fixtureDefaults(pinnedTo: scratch)
        let store = SavedSearchStore(defaults: defaults)
        var budget = SearchRule(field: .ocrText); budget.text = "budget"
        var press = SearchRule(field: .tags); press.tags = ["Press"]
        var group = SearchRule(field: .group); group.combine = .any; group.children = [budget, press]
        let mixed = try XCTUnwrap(store.add(name: "Mixed", search: AdvancedSearch(combine: .all, rules: [group])))
        let text = try XCTUnwrap(store.add(name: "Budget", search: AdvancedSearch(combine: .all, rules: [budget])))
        var missing = SearchRule(field: .ocrText); missing.text = "absentterm"
        let zero = try XCTUnwrap(store.add(name: "Empty", search: AdvancedSearch(combine: .all, rules: [missing])))
        let indexer = ContentIndexer(url: scratch.appendingPathComponent("index.sqlite3"), extractPDFForTesting: { url in
            guard let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return ExtractedContent(fullBody: body, strippedBody: body, classification: nil, pageCount: 2)
        })
        let model = NavigationModel(defaults: defaults, indexer: indexer)
        func waitCounts(_ want: [UUID: Int]) async throws {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, model.smartFolderCounts != want { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertEqual(model.smartFolderCounts, want)
        }
        try await waitCounts([mixed: 2, text: 1, zero: 0])
        let rows = VStack(spacing: 10) {
            ForEach(model.savedSearches.searches) { saved in
                SidebarItemRow(name: saved.name, systemImage: "folder.badge.gearshape",
                               count: model.smartFolderCounts[saved.id])
            }
        }.padding().background(Color.white).environment(\.colorScheme, .light)
        let png = try XCTUnwrap(RenderProbe.pngData(from: rows, size: CGSize(width: 260, height: 130)))
        writeRenderArtifact(png, named: "smart-folder-sidebar-counts.png")
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: png), "smart-folder count rows")

        model.applyScope(try XCTUnwrap(model.savedSearches.searches.first { $0.id == mixed }))
        model.fullTextQuery = "budget"
        model.runFullTextSearch()
        let searchDeadline = Date().addingTimeInterval(5)
        while Date() < searchDeadline, model.ftsPaths != Set([a.path]) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.displayed.map(\.path), [a.path], "typed text narrows within the smart folder")
        model.clearUserFilters()
        XCTAssertEqual(Set(model.displayed.map(\.path)), Set([a.path, b.path]), "clear restores the full base set")
        XCTAssertTrue(model.displayed.allSatisfy { model.searchSnippet(for: $0.path) == nil })
        XCTAssertEqual(model.smartFolderCounts, [mixed: 2, text: 1, zero: 0])

        model.setFolderScope(nested.path)
        model.filter.searchText = "nomatch"
        model.fullTextQuery = "draft"
        model.runFullTextSearch()
        model.recompute()
        XCTAssertTrue(model.displayed.isEmpty)
        XCTAssertEqual(model.smartFolderCounts, [mixed: 2, text: 1, zero: 0], "sidebar counts ignore user narrowing")

        // Re-index one scratch file without opening its smart folder. Counts must follow committed OCR.
        try Data("budget changed".utf8).write(to: b)
        let changedFiles = model.library.files.map { file in
            ArchiveFile(url: file.url, name: file.name, fileType: file.fileType, tags: file.tags,
                        contentModified: Date().addingTimeInterval(5))
        }
        model.library.replaceFilesForTesting(changedFiles)
        try await waitCounts([mixed: 2, text: 2, zero: 0])

        model.excludedFolders.add("Sub")
        try await waitCounts([mixed: 1, text: 1, zero: 0])
        model.savedSearches.update(text, search: AdvancedSearch(combine: .all, rules: [missing]))
        model.savedSearches.update(text, search: AdvancedSearch(combine: .all, rules: [budget]))
        model.savedSearches.delete(zero)
        try await waitCounts([mixed: 1, text: 1])
        XCTAssertFalse(UserDefaults.standard.data(forKey: "savedSearches").map {
            String(decoding: $0, as: UTF8.self).contains(mixed.uuidString)
        } ?? false, "scratch smart folders must never reach the owner's defaults")
        await indexer.closeForTesting()
    }

    private func renderName(_ model: NavigationModel, field: NSTextField, path: String, named: String, expectsSnippet: Bool) throws {
        AppKitTableView.Coordinator.configureNameTextField(
            field, name: "Archival budget memorandum.pdf", dotColor: nil, disambiguator: nil,
            snippet: model.searchSnippet(for: path), fontSize: 13)
        XCTAssertEqual(field.stringValue.contains("\n"), expectsSnippet)
        XCTAssertEqual(field.maximumNumberOfLines, expectsSnippet ? 2 : 1)
        field.appearance = NSAppearance(named: .aqua)
        field.drawsBackground = true
        field.backgroundColor = .white
        let data = try XCTUnwrap(RenderProbe.pngData(fromAppKitView: field, size: CGSize(width: 350, height: 44)))
        writeRenderArtifact(data, named: "\(named).png")
        assertRendersNonBlank(RenderProbe.cgImage(fromPNG: data), named)
    }

}
