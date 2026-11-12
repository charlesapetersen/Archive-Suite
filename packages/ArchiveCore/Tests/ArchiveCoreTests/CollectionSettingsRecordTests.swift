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
    "future":{"source":{"setByUser":{"_0":"2026-11-04T10:00:00Z"}},"value":{"type":"matrix","value":[1]}}},\
    "id":"6F1C2E9A-0000-4000-8000-000000000001","kind":"collection","name":"Letters 1952"},\
    "createdAt":"2026-11-04T09:59:00Z","projectID":"6F1C2E9A-0000-4000-8000-000000000002","projectName":"Correspondence","schemaVersion":1}
    """

    private func run(_ id: String, at date: String, kind: String = "processFiles", version: Int = 1) -> String {
        """
        {"fileCount":12,"id":"\(id)","kind":"\(kind)","schemaVersion":\(version),"startedAt":"\(date)",\
        "settings":{"collectionID":"6F1C2E9A-0000-4000-8000-000000000001","macMemoryGB":16,\
        "processing":{"selectedProvider":{"type":"string","value":"Gemini"},\
        "selectedModelId_Gemini":{"type":"string","value":"gemini-3.7-flash"},"useGateway":{"type":"bool","value":false},\
        "useAppleVision":{"type":"bool","value":false},"odd":{"type":"tensor","value":0}},\
        "projectName":"Correspondence","resolvedAt":"\(date)","runID":"\(id)","schemaVersion":1,\
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
        // The unknown value kind is dropped; the rest survive, by label.
        #expect(r.ownSettings.map(\.key) == ["hours", "mix"])
        #expect(r.ownSettings.last?.value == "typewritten 60%, handwritten 40%")
        #expect(r.ownSettings.last?.source == "set for this collection, measured on 2026-11-04 from 40 photos")
        #expect(r.runFileCount == 3 && r.unreadableRunCount == 1)
        #expect(r.runs.map(\.id) == ["B", "A"])
        let latest = try #require(r.latestRun)
        #expect(latest.kindLabel == "Live Capture")
        #expect(latest.fileCount == 12 && latest.macMemoryGB == 16)
        #expect(latest.reader == "Gemini, gemini-3.7-flash")
        #expect(latest.processing.map(\.key) == ["selectedModelId_Gemini", "selectedProvider", "useAppleVision",
                                                  "useGateway"])
        let byKey = Dictionary(uniqueKeysWithValues: latest.settings.map { ($0.key, $0) })
        #expect(byKey["hours"]?.value == "8 hours")
        #expect(byKey["moneyHabit"]?.source == "built in: Free, on this Mac")
        #expect(byKey["moneyHabit"]?.value == "Nothing is spent")
        #expect(byKey["priorities"]?.value == "dates, then finding documents")
        #expect(byKey["priorities"]?.source == "from the project “Correspondence”, filled by “Letters” on 2026-11-03")
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
        // A folder with no record loads nothing.
        #expect(CollectionSettingsRecord.load(collectionFolder: root) == nil)
    }
}
