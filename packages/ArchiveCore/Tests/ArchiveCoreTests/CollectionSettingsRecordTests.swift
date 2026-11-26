import Darwin
import Foundation
import Testing
@testable import ArchiveCore

/// W46.settings-reader-notes: the read-only side of `SPEC/collection-settings.md`. The documents here are written by
/// hand in the writer's shape; the Processor's settings-layers driver checks the same reader against its real writer.
@Suite struct CollectionSettingsRecordTests {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("csr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private let document = """
    {"collection":{"entries":{"hours":{"source":{"setByUser":{"_0":"2026-11-04T10:00:00Z"}},"value":{"type":"double","value":8}},\
    "mix":{"source":{"measured":{"_0":"2026-11-04T10:00:00Z","sample":40}},"value":{"type":"numbers","value":{"handwritten":40,"typewritten":60}}},\
    "cluster":{"source":{"setByUser":{"_0":"2026-11-04T10:00:00Z"}},"value":{"type":"bool","value":true}},\
    "future":{"source":{"setByUser":{"_0":"2026-11-04T10:00:00Z"}},"value":{"type":"matrix","value":[1]}}},\
    "id":"6F1C2E9A-0000-4000-8000-000000000001","kind":"collection","name":"Letters 1952"},\
    "createdAt":"2026-11-04T09:59:00Z","projectID":"6F1C2E9A-0000-4000-8000-000000000002","projectName":"Correspondence","schemaVersion":1}
    """

    private static let geminiRun = #"{"provider":"Gemini","model":{"id":"gemini-3.7-flash","displayName":"Gemini 3.7 Flash"},"#
        + #""taggingMode":"automatic","ocrWorkerCount":4,"tagVocabulary":["Letters","Bills"],"odd":[{"a":1}]}"#

    private func run(_ id: String, at date: String, kind: String = "processFiles", version: Int = 1,
                     config: String = geminiRun) -> String {
        """
        {"fileCount":12,"id":"\(id)","kind":"\(kind)","schemaVersion":\(version),"startedAt":"\(date)",\
        "settings":{"collectionID":"6F1C2E9A-0000-4000-8000-000000000001","macMemoryGB":16,\
        "run":\(config),\
        "projectName":"Correspondence","resolvedAt":"\(date)","runID":"\(id)","schemaVersion":2,\
        "values":{"hours":{"layer":"collection","source":{"setByUser":{"_0":"2026-11-04T10:00:00Z"}},"value":{"type":"double","value":8}},\
        "moneyHabit":{"value":{"type":"string","value":"none"}},\
        "priorities":{"layer":"project","layerName":"Correspondence","source":{"startingPoint":{"_0":"Letters","_1":"2026-11-03T08:00:00.250Z"}},\
        "value":{"type":"strings","value":["dates","findingDocuments"]}}}}}
        """
    }

    @Test func readsTheDocumentAndRunsNewestFirst() throws {
        let root = try scratch()
        let dir = root.appendingPathComponent(".archivesuite")
        try write(document, to: dir.appendingPathComponent("collection-settings.json"))
        try write(run("A", at: "2026-11-04T10:00:00Z"), to: dir.appendingPathComponent("runs/20261104-100000-A.json"))
        try write(run("B", at: "2026-11-05T10:00:00Z", kind: "liveCapture"),
                  to: dir.appendingPathComponent("runs/20261105-100000-B.json"))
        try write("not json", to: dir.appendingPathComponent("runs/20261106-100000-C.json"))

        let r = try #require(CollectionSettingsRecord.load(collectionFolder: root))
        #expect(r.collectionName == "Letters 1952")
        #expect(r.projectName == "Correspondence")
        #expect(!r.documentIsNewer && !r.documentUnreadable)
        // The unknown value kind is dropped, and so is a value only the general layer holds; the rest survive.
        #expect(r.ownSettings.map(\.key) == ["hours", "mix"])
        #expect(r.ownSettings.last?.value == "typewritten 60%, handwritten 40%")
        #expect(r.ownSettings.last?.source == "set for this collection, measured on 2026-11-04 from 40 pages")
        #expect(r.runFileCount == 3 && r.unreadableRunCount == 1)
        #expect(r.runs.map(\.id) == ["B", "A"])
        let latest = try #require(r.latestRun)
        #expect(latest.kindLabel == "Live Capture")
        #expect(latest.fileCount == 12 && latest.macMemoryGB == 16)
        #expect(latest.reader == "Gemini, gemini-3.7-flash")
        // The run's settings by dotted name; a list of objects is left out.
        #expect(latest.processing.map(\.key) == ["model.displayName", "model.id", "ocrWorkerCount", "provider",
                                                  "tagVocabulary", "taggingMode"])
        #expect(latest.processing.first { $0.key == "tagVocabulary" }?.value == "Letters, Bills")
        let byKey = Dictionary(uniqueKeysWithValues: latest.settings.map { ($0.key, $0) })
        #expect(byKey["hours"]?.value == "8 hours")
        #expect(byKey["moneyHabit"]?.source == "built in: Free, on this Mac")
        #expect(byKey["moneyHabit"]?.value == "Nothing is spent")
        #expect(byKey["priorities"]?.value == "dates, then finding documents")
        #expect(byKey["priorities"]?.source == "from the project “Correspondence”, filled by “Letters” on 2026-11-03")
    }

    /// W49.proc-settings-config-unify: the route in words, from the run's own config.
    @Test func readerNamesTheRunsRoute() throws {
        let root = try scratch()
        let dir = root.appendingPathComponent(".archivesuite")
        try write(document, to: dir.appendingPathComponent("collection-settings.json"))
        let routes = [
            ("V", #"{"provider":"Apple Vision","model":{"id":"macos-vision"}}"#),
            ("G", #"{"provider":"Anthropic","model":{"id":"x"},"gateway":{"modelID":"gemini-3.7-flash","displayName":"Stanford"}}"#),
            ("C", #"{"provider":"Anthropic","model":{"id":"claude-sonnet-5"},"gateway":null}"#),
        ]
        for (i, (id, config)) in routes.enumerated() {
            try write(run(id, at: "2026-11-0\(i + 4)T10:00:00Z", config: config),
                      to: dir.appendingPathComponent("runs/2026110\(i + 4)-100000-\(id).json"))
        }
        let r = try #require(CollectionSettingsRecord.load(collectionFolder: root))
        let readers = Dictionary(uniqueKeysWithValues: r.runs.map { ($0.id, $0.reader) })
        #expect(readers["V"] == "Apple Vision (on this Mac)")
        #expect(readers["G"] == "A gateway, Stanford")
        #expect(readers["C"] == "Claude, claude-sonnet-5")
    }

    @Test func newerSchemaIsNotInterpreted() throws {
        let root = try scratch()
        let dir = root.appendingPathComponent(".archivesuite")
        try write(#"{"schemaVersion":2,"collection":{"name":"x"}}"#, to: dir.appendingPathComponent("collection-settings.json"))
        try write(run("N", at: "2026-11-04T10:00:00Z", version: 2), to: dir.appendingPathComponent("runs/20261104-N.json"))
        let r = try #require(CollectionSettingsRecord.load(collectionFolder: root))
        #expect(r.documentIsNewer && r.collectionName == nil)
        #expect(r.runs.count == 1 && r.runs[0].isNewer && r.runs[0].settings.isEmpty && r.runs[0].kind == "processFiles")
    }

    @Test func linksAndBigFilesAreRefused() throws {
        let real = try scratch()
        try write(document, to: real.appendingPathComponent(".archivesuite/collection-settings.json"))

        // `.archivesuite` itself a link: nothing found.
        let linked = try scratch()
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(".archivesuite"),
                                                   withDestinationURL: real.appendingPathComponent(".archivesuite"))
        #expect(!CollectionSettingsRecord.hasRecord(linked))
        #expect(CollectionSettingsRecord.load(collectionFolder: linked) == nil)

        // The document a link: found, but not read.
        let fileLink = try scratch()
        try FileManager.default.createDirectory(at: fileLink.appendingPathComponent(".archivesuite"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fileLink.appendingPathComponent(".archivesuite/collection-settings.json"),
            withDestinationURL: real.appendingPathComponent(".archivesuite/collection-settings.json"))
        let r = try #require(CollectionSettingsRecord.load(collectionFolder: fileLink))
        #expect(r.documentUnreadable && r.collectionName == nil)

        let big = try scratch()
        let pad = String(repeating: " ", count: CollectionSettingsRecord.maxFileBytes)
        try write(document + pad, to: big.appendingPathComponent(".archivesuite/collection-settings.json"))
        #expect(CollectionSettingsRecord.load(collectionFolder: big)?.documentUnreadable == true)
    }

    @Test func aFIFOIsNeverOpened() throws {
        let root = try scratch()
        let dir = root.appendingPathComponent(".archivesuite/runs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(mkfifo(root.appendingPathComponent(".archivesuite/collection-settings.json").path, 0o600) == 0)
        #expect(mkfifo(dir.appendingPathComponent("20261104-F.json").path, 0o600) == 0)
        // Returns at once rather than blocking in open().
        let r = try #require(CollectionSettingsRecord.load(collectionFolder: root))
        #expect(r.documentUnreadable && r.runs.isEmpty && r.unreadableRunCount == 1)
    }

    @Test func locateWalksUpToTheRootAndNoFurther() throws {
        let root = try scratch()
        let collection = root.appendingPathComponent("Box 3", isDirectory: true)
        try write(document, to: collection.appendingPathComponent(".archivesuite/collection-settings.json"))
        let deep = collection.appendingPathComponent("Folder 2/doc.pdf")
        try FileManager.default.createDirectory(at: deep.deletingLastPathComponent(), withIntermediateDirectories: true)

        #expect(CollectionSettingsRecord.locate(from: deep, within: root)?.lastPathComponent == "Box 3")
        // Without a root only the file's own folder is looked at.
        #expect(CollectionSettingsRecord.locate(from: deep) == nil)
        #expect(CollectionSettingsRecord.locate(from: collection.appendingPathComponent("x.pdf"))?
            .lastPathComponent == "Box 3")
        // The root bounds the walk: a record above it is not found.
        #expect(CollectionSettingsRecord.locate(from: deep, within: deep.deletingLastPathComponent()) == nil)
        // A file outside the root finds nothing.
        #expect(CollectionSettingsRecord.locate(from: deep, within: try scratch()) == nil)
        // A root spelled through a link still contains its files.
        let alias = try scratch().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(CollectionSettingsRecord.locate(from: deep, within: alias)?.lastPathComponent == "Box 3")
        // A folder with no record loads nothing.
        #expect(CollectionSettingsRecord.load(collectionFolder: root) == nil)
    }

    /// W49.reader-folder-date-day-first: the order the Reader reads a folder's numeric date in.
    @Test func numericDateOrderFromTheCollectionOrItsNewestRun() throws {
        func layer(_ entries: String) -> String {
            """
            {"collection":{"entries":{\(entries)},"id":"C","kind":"collection","name":"Letters"},"schemaVersion":1}
            """
        }
        let order = #""numericDatesDayFirst":{"source":{"setByUser":{"_0":"2026-11-24T10:00:00Z"}},"value":{"type":"bool","value":true}}"#
        func runRecord(_ id: String, at date: String, dayFirst: Bool?) -> String {
            let value = dayFirst.map { #","values":{"numericDatesDayFirst":{"layer":"general","value":{"type":"bool","value":\#($0)}}}"# } ?? ""
            return #"{"id":"\#(id)","kind":"processFiles","schemaVersion":1,"startedAt":"\#(date)","settings":{"schemaVersion":1\#(value)}}"#
        }
        let root = try scratch()
        let collection = root.appendingPathComponent("Letters", isDirectory: true)
        let folder = collection.appendingPathComponent("Box 1/Folder 2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dir = collection.appendingPathComponent(".archivesuite")

        // No record anywhere: month first.
        #expect(!CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: root))
        // The collection's own value, found from a folder below it.
        try write(layer(order), to: dir.appendingPathComponent("collection-settings.json"))
        #expect(CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: root))
        // Without its own value, the newest run that resolved one: here the older run said day first, the newer one
        // (from the general layer) month first, and a run with no value is passed over.
        try write(layer(""), to: dir.appendingPathComponent("collection-settings.json"))
        try write(runRecord("A", at: "2026-11-20T10:00:00Z", dayFirst: true), to: dir.appendingPathComponent("runs/20261120-100000-A.json"))
        #expect(CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: root))
        try write(runRecord("B", at: "2026-11-21T10:00:00Z", dayFirst: false), to: dir.appendingPathComponent("runs/20261121-100000-B.json"))
        try write(runRecord("C", at: "2026-11-22T10:00:00Z", dayFirst: nil), to: dir.appendingPathComponent("runs/20261122-100000-C.json"))
        #expect(!CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: root))
        // The collection's own value wins over its runs; a record outside the root is not read.
        try write(layer(order), to: dir.appendingPathComponent("collection-settings.json"))
        #expect(CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: root))
        #expect(!CollectionSettingsRecord.numericDatesDayFirst(directory: folder, within: folder))
    }
}
